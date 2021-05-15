# frozen_string_literal: true

module Bridgetown
  class Document
    extend Forwardable
    include DataAccessible
    include Comparable
    include LayoutPlaceable
    include LiquidRenderable
    include Publishable

    attr_reader :path, :site, :extname, :collection, :type
    attr_accessor :content, :output

    def_delegator :self, :read_post_data, :post_read

    YAML_FRONT_MATTER_REGEXP = %r!\A(---\s*\n.*?\n?)^((---|\.\.\.)\s*$\n?)!m.freeze
    DATELESS_FILENAME_MATCHER = %r!^(?:.+/)*(.*)(\.[^.]+)$!.freeze
    DATE_FILENAME_MATCHER = %r!^(?>.+/)*?(\d{2,4}-\d{1,2}-\d{1,2})-([^/]*)(\.[^.]+)$!.freeze

    YAML_FILE_EXTS = %w(.yaml .yml).freeze

    #

    # Class-wide cache to stash and retrieve regexp to detect "super-directories"
    # of a particular Bridgetown::Document object.
    #
    # dirname - The *special directory* for the Document.
    #           e.g. "_posts" for Documents from the `site.posts` collection.
    def self.superdirs_regex(dirname)
      @superdirs_regex ||= {}
      @superdirs_regex[dirname] ||= %r!#{dirname}.*!
    end

    #

    # Create a new Document.
    #
    # path - the path to the file
    # relations - a hash with keys :site and :collection, the values of which
    #             are the Bridgetown::Site and Bridgetown::Collection to which this
    #             Document belong.
    #
    # Returns nothing.
    def initialize(path, relations = {})
      @site = relations[:site]
      @path = path
      @extname = File.extname(path)
      @collection = relations[:collection]
      @type = @collection.label.to_sym

      @has_yaml_header = nil

      data.default_proc = proc do |_, key|
        site.frontmatter_defaults.find(relative_path, type, key.to_s)
      end

      trigger_hooks(:post_init)
    end

    # Fetch the Document's data.
    #
    # Returns a Hash containing the data. An empty hash is returned if
    #   no data was read.
    def data
      @data ||= HashWithDotAccess::Hash.new
    end

    # Merge some data in with this document's data.
    #
    # Returns the merged data.
    def merge_data!(other, source: "YAML front matter")
      merge_categories!(other)
      Utils.deep_merge_hashes!(data, other)
      merge_date!(source)
      data
    end

    # Returns the document date. If metadata is not present then calculates it
    # based on Bridgetown::Site#time or the document file modification time.
    #
    # Return document date string.
    def date
      data["date"] ||= site.time # TODO: this doesn't reflect documented behavior
    end

    # Return document file modification time in the form of a Time object.
    #
    # Return document file modification Time object.
    def source_file_mtime
      File.mtime(path)
    end

    # The path to the document, relative to the collections_dir.
    #
    # Returns a String path which represents the relative path from the collections_dir
    # to this document.
    def relative_path
      @relative_path ||= path.sub("#{site.collections_path}/", "")
    end

    # FIXME: spinning up a new Renderer object just to get an extension
    # seems excessive
    #
    # The output extension of the document.
    #
    # Returns the output extension
    def output_ext
      @output_ext ||= Bridgetown::Renderer.new(site, self).output_ext
    end

    # The base filename of the document, without the file extname.
    #
    # Returns the basename without the file extname.
    def basename_without_ext
      @basename_without_ext ||= File.basename(path, ".*")
    end

    # The base filename of the document.
    #
    # Returns the base filename of the document.
    def basename
      @basename ||= File.basename(path)
    end

    # Produces a "cleaned" relative path.
    # The "cleaned" relative path is the relative path without the extname
    #   and with the collection's directory removed as well.
    # This method is useful when building the URL of the document.
    #
    # NOTE: `String#gsub` removes all trailing periods (in comparison to `String#chomp`)
    #
    # Examples:
    #   When relative_path is "_methods/site/generate...md":
    #     cleaned_relative_path
    #     # => "/site/generate"
    #
    # Returns the cleaned relative path of the document.
    def cleaned_relative_path
      @cleaned_relative_path ||=
        relative_path[0..-extname.length - 1]
          .sub(collection.relative_directory, "")
          .gsub(%r!\.*\z!, "")
    end

    # Determine whether the document is a YAML file.
    #
    # Returns true if the extname is either .yml or .yaml, false otherwise.
    def yaml_file?
      YAML_FILE_EXTS.include?(extname)
    end

    # The URL template where the document would be accessible.
    #
    # Returns the URL template for the document.
    def url_template
      collection.url_template
    end

    # Construct a Hash of key-value pairs which contain a mapping between
    #   a key in the URL template and the corresponding value for this document.
    #
    # Returns the Hash of key-value pairs for replacement in the URL.
    def url_placeholders
      @url_placeholders ||= Drops::UrlDrop.new(self)
    end

    # The permalink for this Document.
    # Permalink is set via the data Hash.
    #
    # Returns the permalink or nil if no permalink was set in the data.
    def permalink
      data&.permalink
    end

    # The computed URL for the document. See `Bridgetown::URL#to_s` for more details.
    #
    # Returns the computed URL for the document.
    def url
      @url ||= URL.new(
        template: url_template,
        placeholders: url_placeholders,
        permalink: permalink
      ).to_s
    end

    # The full path to the output file.
    #
    # base_directory - the base path of the output directory
    #
    # Returns the full path to the output file of this document.
    def destination(base_directory)
      dest = site.in_dest_dir(base_directory)
      path = site.in_dest_dir(dest, URL.unescape_path(url))
      if url.end_with? "/"
        path = File.join(path, "index.html")
      else
        path << output_ext unless path.end_with? output_ext
      end
      path
    end

    # Write the generated Document file to the destination directory.
    #
    # dest - The String path to the destination dir.
    #
    # Returns nothing.
    def write(dest)
      path = destination(dest)
      FileUtils.mkdir_p(File.dirname(path))
      Bridgetown.logger.debug "Writing:", path
      File.write(path, output, mode: "wb")

      trigger_hooks(:post_write)
    end

    # Read in the file and assign the content and data based on the file contents.
    # Merge the frontmatter of the file with the frontmatter default
    # values
    #
    # Returns nothing.
    def read(opts = {})
      Bridgetown.logger.debug "Reading:", relative_path

      if yaml_file?
        @data = YAMLParser.load_file(path)
      else
        begin
          merge_defaults
          read_content(**opts)
          read_post_data
        rescue StandardError => e
          handle_read_error(e)
        end
      end
    end

    # Create a Liquid-understandable version of this Document.
    #
    # Returns a Hash representing this Document's data.
    def to_liquid
      @to_liquid ||= Drops::DocumentDrop.new(self)
    end

    # The inspect string for this document.
    # Includes the relative path and the collection label.
    #
    # Returns the inspect string for this document.
    def inspect
      "#<#{self.class} #{relative_path} collection=#{collection.label}>"
    end

    # Compare this document against another document.
    # Comparison is a comparison between the 2 paths of the documents.
    #
    # Returns -1, 0, +1 or nil depending on whether this doc's path is less than,
    #   equal or greater than the other doc's path. See String#<=> for more details.
    def <=>(other)
      return nil unless other.respond_to?(:data)

      cmp = data["date"] <=> other.data["date"]
      cmp = path <=> other.path if cmp.nil? || cmp.zero?
      cmp
    end

    # Determine whether this document should be written.
    # Based on the Collection to which it belongs.
    #
    # True if the document has a collection and if that collection's #write?
    # method returns true, and if the site's Publisher will publish the document.
    # False otherwise.
    def write?
      collection&.write? && site.publisher.publish?(self)
    end

    # The Document excerpt_separator, from the YAML Front-Matter or site
    # default excerpt_separator value
    #
    # Returns the document excerpt_separator
    def excerpt_separator
      @excerpt_separator ||= (data["excerpt_separator"] || site.config["excerpt_separator"]).to_s
    end

    # Whether to generate an excerpt
    #
    # Returns true if the excerpt separator is configured.
    def generate_excerpt?
      !excerpt_separator.empty?
    end

    def next_doc
      pos = collection.docs.index { |post| post.equal?(self) }
      collection.docs[pos + 1] if pos && pos < collection.docs.length - 1
    end

    def previous_doc
      pos = collection.docs.index { |post| post.equal?(self) }
      collection.docs[pos - 1] if pos&.positive?
    end

    def trigger_hooks(hook_name, *args)
      Bridgetown::Hooks.trigger collection.label.to_sym, hook_name, self, *args if collection
      Bridgetown::Hooks.trigger :documents, hook_name, self, *args
    end

    def id
      @id ||= File.join(File.dirname(url), (data["slug"] || basename_without_ext).to_s)
    end

    # Calculate related posts.
    #
    # Returns an Array of related Posts.
    def related_posts
      @related_posts ||= Bridgetown::RelatedPosts.new(self).build
    end

    # Override of method_missing to check in @data for the key.
    def method_missing(method, *args, &blck)
      if data.key?(method.to_s)
        Bridgetown::Deprecator.deprecation_message "Document##{method} is now a key "\
                           "in the #data hash."
        Bridgetown::Deprecator.deprecation_message "Called by #{caller(0..0)}."
        data[method.to_s]
      else
        super
      end
    end

    def respond_to_missing?(method, *)
      data.key?(method.to_s) || super
    end

    private

    def merge_categories!(other)
      if other.key?("categories") && !other["categories"].nil?
        other["categories"] = other["categories"].split if other["categories"].is_a?(String)
        other["categories"] = (data["categories"] || []) | other["categories"]
      end
    end

    def merge_date!(source)
      if data.key?("date")
        data["date"] = Utils.parse_date(
          data["date"].to_s,
          "Document '#{relative_path}' does not have a valid date in the #{source}."
        )
      end
    end

    def merge_defaults
      defaults = @site.frontmatter_defaults.all(relative_path, type)
      merge_data!(defaults, source: "front matter defaults") unless defaults.empty?
    end

    def read_content(**opts)
      self.content = File.read(path, **Utils.merged_file_read_opts(site, opts))
      if content =~ YAML_FRONT_MATTER_REGEXP
        self.content = $POSTMATCH
        data_file = YAMLParser.load(Regexp.last_match(1))
        merge_data!(data_file, source: "YAML front matter") if data_file
      end
    end

    def read_post_data
      populate_title
      populate_categories
      populate_tags
      determine_locale
      generate_excerpt
    end

    def handle_read_error(error)
      if error.is_a? Psych::SyntaxError
        Bridgetown.logger.error "Error:", "YAML Exception reading #{path}: #{error.message}"
      else
        Bridgetown.logger.error "Error:", "could not read file #{path}: #{error.message}"
      end

      if site.config["strict_front_matter"] || error.is_a?(Bridgetown::Errors::FatalException)
        raise error
      end
    end

    def populate_title
      if relative_path =~ DATE_FILENAME_MATCHER
        date, slug, ext = Regexp.last_match.captures
        modify_date(date)
      elsif relative_path =~ DATELESS_FILENAME_MATCHER
        slug, ext = Regexp.last_match.captures
      end

      # slugs shouldn't end with a period
      # `String#gsub!` removes all trailing periods (in comparison to `String#chomp!`)
      slug.gsub!(%r!\.*\z!, "")

      # Try to ensure the user gets a title.
      data["title"] ||= Utils.titleize_slug(slug)
      # Only overwrite slug & ext if they aren't specified.
      data["slug"]  ||= slug
      data["ext"]   ||= ext
    end

    def populate_categories
      data.categories = Utils.pluralized_array_from_hash(
        data, :category, :categories
      ).map(&:to_s)
    end

    def populate_tags
      data.tags = Utils.pluralized_array_from_hash(data, :tag, :tags)
    end

    def determine_locale
      unless data["locale"]
        # if locale key isn't directly set, look for alternative front matter
        # or look at the filename pattern: slug.locale.ext
        alernative = data["language"] || data["lang"] ||
          basename_without_ext.split(".")[1..-1].last

        data["locale"] = alernative if !alernative.nil? &&
          site.config[:available_locales].include?(alernative)
      end
    end

    def modify_date(date)
      if !data["date"] || data["date"].to_i == site.time.to_i
        merge_data!({ "date" => date }, source: "filename")
      end
    end

    def generate_excerpt
      data["excerpt"] ||= Bridgetown::Excerpt.new(self) if generate_excerpt?
    end
  end
end
