require File.expand_path(File.dirname(__FILE__) + "/base.rb")

require 'csv'

# Importer for Friends+Me Google+ Exporter (F+MG+E) output.
#
# Takes the full path (absolute or relative) to
# * each of the F+MG+E JSON export files you want to import
# * the F+MG+E google-plus-image-list.csv file,
# * a categories.json file you write to describe how the Google+
#   categories map to Discourse categories, subcategories, and tags.
#
# You can provide all the F+MG+E JSON export files in a single import
# run.  This will be the fastest way to do the entire import if you
# have enough memory and disk space.  It will work just as well to
# import each F+MG+E JSON export file separately.  This might be
# valuable if you have memory or space limitations, as the memory to
# hold all the data from the F+MG+E JSON export files is one of the
# key resources used by this script.
#
# Create an initial empty ("{}") categories.json file, and the import
# script will write a .new file for you to fill in the details.
# You will probably want to use jq to reformat the .new file before
# trying to edit it.  `jq . categories.json.new > categories.json`
#
# Provide a filename that ends with "upload-paths.txt" and the names
# of each of the files uploaded will be written to the file with that
# name
#
# Edit values at the top of the script to fit your preferences

class ImportScripts::FMGP < ImportScripts::Base

  def initialize
    super

    @system_user = Discourse.system_user
    SiteSetting.max_image_size_kb = 40960
    SiteSetting.max_attachment_size_kb = 40960
    @min_title_words = 3
    @max_title_words = 14
    @min_title_characters = 12

    # JSON files produced by F+MG+E as an export of a community
    @feeds = []

    # CSV is map to downloaded images
    @images = {}

    # Tags to apply to every topic; empty Array to not have any tags applied everywhere
    @globaltags = [ "gplus" ]

    @imagefiles = nil

    # categories.json file is map:
    # "google-category-uuid": {
    #   "name": 'google+ category name',
    #   "category": 'category name',
    #   "parent": 'parent name', # optional
    #   "create": true, # optional
    #   "tags": ['list', 'of', 'tags'] optional
    # }
    # Start with '{}', let the script generate categories.json.new once, then edit and re-run
    @categories = {}

    # keep track of the filename in case we need to write a .new file
    @categories_filename = nil
    # dry run parses but doesn't create
    @dryrun = false
    # every argument is a filename, do the right thing based on the file name
    ARGV.each do |arg|
      if arg.end_with?('.csv')
        # CSV files produced by F+MG+E have "URL";"IsDownloaded";"FileName";"FilePath";"FileSize"
        CSV.foreach(arg, :headers => true, :col_sep => ';') do |row|
          @images[row[0]] = {
            :filename => row[2],
            :filepath => row[3],
            :filesize => row[4]
          }
        end
      elsif arg.end_with?("upload-paths.txt")
        @imagefiles = File.open(arg, "w")
      elsif arg.end_with?('categories.json')
        @categories_filename = arg
        @categories = load_fmgp_json(arg)
      elsif arg.end_with?('.json')
        @feeds << load_fmgp_json(arg)
      elsif arg == '--dry-run'
        @dryrun = true
      end
    end

    raise RuntimeError.new("Must provide a categories.json file") if @categories_filename.nil?

    # store the actual category objects looked up in the database
    @cats = {}
    # remember google auth DB lookup results
    @emails = {}
    @users = {}
    @google_ids = {}
    # remember uploaded images
    @uploaded = {}
    # count uploaded file size
    @totalsize = 0

  end

  def execute
    puts "", "Importing from Friends+Me Google+ Exporter..."

    read_categories
    check_categories
    map_categories

    import_users
    import_posts

    # No need to set trust level 0 for any imported users unless F+MG+E gets the
    # ability to add +1 data, in which case users who have only done a +1 and
    # neither posted nor commented should be TL0, in which case this should be
    # called after all other processing done
    # update_tl0

    @imagefiles.close() if !@imagefiles.nil?
    puts "", "Uploaded #{@totalsize} bytes of image files"
    puts "", "Done"
  end

  def load_fmgp_json(filename)
    raise RuntimeError.new("File #{filename} not found") if !File.exists?(filename)
    JSON.parse(File.read(filename))
  end

  def read_categories
    @feeds.each do |feed|
      feed["accounts"].each do |account|
        account["communities"].each do |community|
          community["categories"].each do |category|
            if !@categories[category["id"]].present?
               # Create empty entries to write and fill in manually
               @categories[category["id"]] = {
                 "name" => category["name"],
                 "community" => community["name"],
                 "category" => "",
                 "parent" => nil,
               }
            elsif !@categories[category["id"]]["community"].present?
              @categories[category["id"]]["community"] = community["name"]
            end
          end
        end
      end
    end
  end

  def check_categories
    # raise a useful exception if necessary data not found in categories.json
    incomplete_categories = []
    @categories.each do |id, c|
      if !c["category"].present?
        # written in JSON without a "category" key at all
        c["category"] = ""
      end
      if c["category"].empty?
        # found in read_categories or not yet filled out in categories.json
        incomplete_categories << c["name"]
      end
    end
    if !incomplete_categories.empty?
      categories_new = "#{@categories_filename}.new"
      File.open(categories_new, "w") do |f|
        f.write(@categories.to_json)
        raise RuntimeError.new("Category file missing categories for #{incomplete_categories}, edit #{categories_new} and rename it to #{@category_filename} before running the same import")
      end
    end
  end

  def map_categories
    puts "", "Mapping categories from Google+ to Discourse..."

    @categories.each do |id, cat|
      # Two separate sub-categories can have the same name, so need to identify by parent
      if cat["parent"].present? and !cat["parent"].empty?
        parent = Category.where(name: cat["parent"]).first
        raise RuntimeError.new("Could not find parent category #{cat["parent"]}") if parent.nil?
        category = Category.where(name: cat["category"], parent_category_id: parent.id).first
      else
        category = Category.where(name: cat["category"]).first
      end
      raise RuntimeError.new("Could not find category #{cat["category"]} for #{cat}") if category.nil?
      @cats[id] = category
    end
  end

  def import_users
    puts '', "Importing Google+ post and comment author users..."

    # collect authors of both posts and comments
    @feeds.each do |feed|
      feed["accounts"].each do |account|
        account["communities"].each do |community|
          community["categories"].each do |category|
            category["posts"].each do |post|
              import_author_user(post["author"])
              if post["message"].present?
                import_message_users(post["message"])
              end
              post["comments"].each do |comment|
                import_author_user(comment["author"])
                if comment["message"].present?
                  import_message_users(comment["message"])
                end
              end
            end
          end
        end
      end
    end

    return if @dryrun

    # now create them all
    create_users(@users) do |id, u|
      {
        id: id,
        email: u[:email],
        name: u[:name],
        post_create_action: u[:post_create_action]
      }
    end
  end

  def import_author_user(author)
    id = author["id"]
    name = author["name"]
    import_google_user(id, name)
  end

  def import_message_users(message)
    message.each do |fragment|
      if fragment[0] == 3 and !fragment[2].nil?
        # deleted G+ users show up with a null ID
        import_google_user(fragment[2], fragment[1])
      end
    end
  end

  def import_google_user(id, name)
    if !@emails[id].present?
      google_user_info = ::GoogleUserInfo.find_by(google_user_id: id.to_i)
      if google_user_info.nil?
        # create new google user on system; expect this user to merge
        # when they later log in with google authentication
        # Note that because email address is not included in G+ data, we
        # don't know if they already have another account not yet associated
        # with GoogleUserInfo. If they didn't log in, they'll have an
        # @gplus.invalid address associated with their account
        email = "#{id}@gplus.invalid"
        @users[id] = {
          :email => email,
          :name => name,
          :post_create_action => proc do |newuser|
            newuser.approved = true
            newuser.approved_by_id = @system_user.id
            newuser.approved_at = newuser.created_at
            newuser.save
            ::GoogleUserInfo.create(google_user_id: id, user: newuser)
            @google_ids[id] = newuser.id
          end
        }
      else
        # user already on system
        @google_ids[id] = google_user_info.user_id
        email = google_user_info.email
      end
      @emails[id] = email
    end
  end

  def import_posts
    # "post" is confusing:
    # - A google+ post is a discourse topic
    # - A google+ comment is a discourse post
    topics = 0
    posts = 0

    puts '', "Importing Google+ posts and comments..."

    @feeds.each do |feed|
      feed["accounts"].each do |account|
        account["communities"].each do |community|
          community["categories"].each do |category|
            category["posts"].each do |post|
              # G+ post / Discourse topic
              import_topic(post, category)
            end
          end
        end
      end
    end
  end

  def import_topic(post, category)
    # no parent for discourse topics / G+ posts
    postmap = make_postmap(post, category, nil)
    p = create_post(postmap, postmap[:id]) if !@dryrun
    # iterate over comments in post
    post["comments"].each do |comment|
      # category is nil for comments
      commentmap = make_postmap(comment, nil, p)
      new_comment = create_post(commentmap, commentmap[:id]) if !@dryrun
    end
  end

  def make_postmap(post, category, parent)
    created_at = Time.zone.parse(post["createdAt"])

    user_id = user_id_from_imported_user_id(post["author"]["id"])
    if user_id.nil?
      user_id = @google_ids[post["author"]["id"]]
    end

    mapped = {
      :id => post["id"],
      :user_id => user_id,
      :created_at => created_at,
      :raw => formatted_message(post),
      :cook_method => Post.cook_methods[:regular],
    }

    # nil category for comments, set for posts, so post-only things here
    if !category.nil?
      cat_id = category["id"]
      mapped[:title] = parse_title(post, created_at)
      mapped[:category] = @cats[cat_id].id
      mapped[:tags] = Array.new(@globaltags)
      if @categories[cat_id]["tags"].present?
        mapped[:tags].append(@categories[cat_id]["tags"]).flatten!
      end
    else
      mapped[:topic_id] = parent.topic_id if !@dryrun
    end
    # FIXME: import G+ "+1" as "like" if F+MG+E feature request implemented

    return mapped
  end

  def parse_title(post, created_at)
    # G+ has no titles, so we have to make something up
    if post["message"].present?
      title_text(post, created_at)
    else
      # probably just posted an image and/or album
      untitled(post["author"]["name"], created_at)
    end
  end

  def title_text(post, created_at)
    words = message_text(post["message"])
    if words.empty? or words.join("").length < @min_title_characters or words.length < @min_title_words
      # database has minimum length
      # short posts appear not to work well as titles most of the time (in practice)
      return untitled(post["author"]["name"], created_at)
    end

    words = words[0..(@max_title_words-1)]
    lastword = nil

    (3..(words.length-1)).each do |i|
      # prefer full stop
      if words[i].end_with?(".")
        lastword = i
      end
    end

    if lastword.nil?
      # fall back on other punctuation
      (3..(words.length-1)).each do |i|
        if words[i].end_with?(',', ';', ':', '?')
          lastword = i
        end
      end
    end

    if !lastword.nil?
      # found a logical terminating word
      words = words[0..lastword]
    end

    # database has max title length, which is longer than a good display shows anyway
    title = words.join(" ").scan(/.{1,254}/)[0]
  end

  def untitled(name, created_at)
      "Google+ post by #{name} on #{created_at}"
  end

  def message_text(message)
    # only words, no markup
    words = []
    text_types = [0, 3]
    message.each do |fragment|
      if text_types.include?(fragment[0])
        fragment[1].split().each do |word|
          words << word
        end
      elsif fragment[0] == 2
        # use the display text of a link
        words << fragment[1]
      end
    end
    return words
  end

  def formatted_message(post)
    lines = []
    if post["message"].present?
      post["message"].each do |fragment|
        lines << formatted_message_fragment(fragment, post)
      end
    end
    # yes, both "image" and "images" :(
    if post["image"].present?
      lines << "\n#{formatted_link(post["image"]["proxy"])}\n"
    end
    if post["images"].present?
      post["images"].each do |image|
        lines << "\n#{formatted_link(image["proxy"])}\n"
      end
    end
    lines.join("")
  end

  def formatted_message_fragment(fragment, post)
    # markdown does not nest reliably the same as either G+'s markup or what users intended in G+, so generate HTML codes
    # this method uses return to make sure it doesn't fall through accidentally
    if fragment[0] == 0
      # Random zero-width join characters break the output; in particular, they are
      # common after plus-references and break @name recognition. Just get rid of them.
      # Also deal with 0x80 (really‽) and non-breaking spaces
      text = fragment[1].gsub(/(\u200d|\u0080)/,"").gsub(/\u00a0/," ")
      if fragment[2].nil?
        return text
      else
        if fragment[2]["italic"].present?
          return "<i>#{text}</i>"
        elsif fragment[2]["bold"].present?
          return "<b>#{text}</b>"
        elsif fragment[2]["strikethrough"].present?
          # s more likely than del to represent user intent?
          return "<s>#{text}</s>"
        else
          raise RuntimeError.new("markdown code #{fragment[2]} not recognized!")
        end
      end
    elsif fragment[0] == 1
      return "\n"
    elsif fragment[0] == 2
      return formatted_link_text(fragment[2], fragment[1])
    elsif fragment[0] == 3
      # reference to a user
      if fragment[2].nil?
        # deleted G+ users show up with a null ID
        return "<b>+#{fragment[1]}</b>"
      end
      # G+ occasionally doesn't put proper spaces after users
      if user = find_user_by_import_id(fragment[2])
        # user was in this import's authors
        return "@#{user.username} "
      else
        if google_user_info = ::GoogleUserInfo.find_by(google_user_id: fragment[2])
          # user was not in this import, but has logged in or been imported otherwise
          user = User.find(google_user_info.user_id)
          return "@#{user.username} "
        else
          raise RuntimeError.new("Google user #{fragment[1]} (id #{fragment[2]}) not imported") if !@dryrun
          # if you want to fall back to their G+ name, just erase the raise above,
          # but this should not happen
          return "<b>+#{fragment[1]}</b>"
        end
      end
    elsif fragment[0] == 4
      # hashtag, the first hash is literal
      return "##{fragment[1]}"
    else
      raise RuntimeError.new("message code #{fragment[0]} not recognized!")
    end
  end

  def formatted_link(url)
    formatted_link_text(url, url)
  end

  def formatted_link_text(url, text)
    # two ways to present images attached to posts; you may want to edit this for preference
    # - display: embedded_image_html(upload)
    # - download links: attachment_html(upload, text)
    # you might even want to make it depend on the file name.
    if @images[text].present?
      # F+MG+E provides the URL it downloaded in the text slot
      # we won't use the plus url at all since it will disappear anyway
      url = text
    end
    if @uploaded[url].present?
      upload = @uploaded[url]
      return "\n#{embedded_image_html(upload)}"
    elsif @images[url].present?
      @imagefiles.write("#{@images[url][:filepath]}\n") if !@imagefiles.nil?
      upload = create_upload(@system_user.id, @images[url][:filepath], @images[url][:filename])
      @totalsize += @images[url][:filesize].to_i
      @uploaded[url] = upload
      return "\n#{embedded_image_html(upload)}"
    end
    if text == url
      # leave the URL bare and Discourse will do the right thing
      return url
    else
      # It turns out that the only place we get here, google has done its own text
      # interpolation that doesn't look good on Discourse, so while it looks like
      # this should be:
      # return "[#{text}](#{url})"
      # it actually looks better to throw away the google-provided text:
      return url
    end
  end
end

if __FILE__ == $0
  ImportScripts::FMGP.new.perform
end
