
# NOTE: This whole file is one big hack. Don't judge.

require 'git'
require 'fileutils'
require 'find'
require 'rexml/document'
require 'rexml/xpath'
require 'pathname'
require 'json'
require 'uri'
require 'set'
require 'yaml'
require "net/http"
require 'thread'

require 'rugged'
require 'nokogiri'
require 'colorize'
require 'typhoeus'
require 'pandoc-ruby'

require 'mercurial-ruby'
require File.expand_path('../_ruby_libs/svn_wc/lib/svn_wc', File.dirname(__FILE__))
require 'svn/core'

$fetched_uris = {}
$debug = false

# Debug puts
def dputs(s)
  if $debug
    puts s
  end
end

def cleanup_uri(uri)
  if uri.nil? then return uri end

  p_uri = URI(uri)

  # googlecode uris need to be http and not https otherwise *boom*
  if p_uri.hostname.include? 'googlecode'
    p_uri.scheme = 'http'
  end

  return p_uri.to_s
end

class AnomalyLogger
  @@anomalies = []

  def record(repo, snapshot, message)
    @@anomalies << {'repo' => repo, 'snapshot' => snapshot, 'message' => message}
  end
end

# Version control systems

class VCS
  # This represents a working copy of a remote repository
  # superlight abstract vcs wrapper
  #
  # features:
  #   - update from remote
  #   - list branches
  #   - list tags
  #   - checkout specific branch / tag
  #   - get latest commit date

  attr_accessor :local_path, :uri, :type
  def initialize(local_path, uri, type)
    @local_path = local_path
    @uri = uri
    @type = type
  end

  def uri_ok?()
    # make sure it is defined
    if @uri.nil? then return false end

    # make sure the uri actually exists
    resp = Typhoeus.get(@uri, followlocation: true, nosignal: true, connecttimeout: 3.0)
    if resp.code == 404 or resp.code == 403
      puts ("ERROR: Code "+resp.code.to_s+" bad URI: " + @uri).red
      return false
    elsif resp.timed_out?
      puts ("ERROR: Timed out URI: " + @uri).red
      return false
    elsif resp.success?
      return true
    end

    puts ("ERROR: Bad URI: " + @uri).red
    return false
  end

  def hash
    return [local_path].hash
  end

  def eql?(other)
    return other.local_path == @local_path
  end

end

class GIT < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'git')

    @r = nil
    @origin = nil
    @remote_head = nil

    if File.exist?(@local_path)
      @r = Rugged::Repository.new(@local_path)
      dputs " - opened git repository at: " << @local_path << " from uri: " << @uri
    else
      @r = Rugged::Repository.init_at(@local_path)
      dputs " - initialized new git repository at: " << @local_path << " from uri: " << @uri
    end

    @origin = @r.remotes['origin']

    if @origin.nil? and self.uri_ok?
      # add remote
      dputs " - adding remote for " << @uri << " to " << @local_path
      @origin = @r.remotes.create('origin', @uri)
    end
  end

  def valid?()
    return (not @origin.nil?)
  end

  def fetch()
    # fetch the remote
    unless $fetched_uris.key?(@uri)
      if true or (File.mtime(File.join(@local_path,'.git')) < (Time.now() - (60*60*24)))
        begin
          dputs " - fetching remote from: " + @uri
          @r.fetch(@origin)
        rescue
          puts ("ERROR: could not fetch git repository from uri: " + @uri).red
        end
      else
        dputs " - not fetching remote "
      end
      # this is no longer useful now that repos are all independent on disk
      #$fetched_uris[@uri] = true
    end
  end

  def checkout(version)

    if version.nil? then return end

    begin
      dputs " --- checking out " << version.name.to_s << " from remote: " << version.remote_name.to_s << " uri: " << @uri
      @r.checkout(version)
    rescue
      dputs " --- resetting hard to " << version.name.to_s
      @r.reset(version.name, :hard)
    end
  end

  def get_last_commit_time()
    return @r.last_commit.time.strftime('%F')
  end

  def get_version(distro, explicit_version = nil)

    # remote head
    if explicit_version == 'REMOTE_HEAD'
      @r.branches.each() do |branch|
        branch.remote.ls.each do |remote_ref|
          if remote_ref[:local] == false and remote_ref[:name] == 'HEAD'
            branch_name = branch.name.split('/')[-1]
            return remote_ref[:oid], branch_name
          end
        end
      end

      return nil, nil
    end

    # get the version if it's a branch
    @r.branches.each() do |branch|
      # get the branch shortname
      branch_name = branch.name.split('/')[-1]

      # detached branches are those checked out by the system but not given names
      if branch.name.include? 'detached' then next end
      if branch.remote_name != 'origin' then next end

      # NOTE: no longer need to check remote names #if branch.remote_name != repo.id then next end

      #dputs " -- examining branch " << branch.name << " trunc: " << branch_name << " from remote: " << branch.remote_name
      #puts " - should have " << distro << " version " << explicit_version.to_s

      # save the branch as the version if it matches either the explicit
      # version or the distro name
      if explicit_version
        if branch_name == explicit_version
          return branch, branch_name
        end
      elsif branch_name.include? distro
        return branch, branch_name
      end
    end

    # get the version if it's a tag
    @r.tags.each do |tag|
      tag_name = tag.to_s

      # save the tag if it matches either the explicit version or the distro name
      if explicit_version
        if tag_name == explicit_version
          return tag, tag_name
        end
      elsif tag_name.include? distro
        return tag, tag_name
      end
    end

    return nil, nil
  end
end

class HG < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'hg')

    @r = nil
    @origin = nil

    if self.uri_ok?
      if File.exist?(@local_path) and File.exist?(File.join(@local_path,'.hg'))
        @r = Mercurial::Repository.open(@local_path)
        dputs " - opened hg repository at: " << @local_path << " from uri: " << @uri
      else
        @r = Mercurial::Repository.clone(@uri, @local_path, {})
        dputs " - initialized new hg repository at: " << @local_path << " from uri: " << @uri
      end
    else
      puts ("ERROR: could not reach hg repository at uri: " + @uri).red
    end
  end

  def valid?()
    return (not @r.nil?)
  end

  def fetch()
    # fetch the remote
    if self.valid?
      @r.pull()
    end
  end

  def checkout(version)
    if self.valid?
      dputs " --- checking out " << version.to_s << " uri: " << @uri
      @r.shell.hg(['update ?', version])
    else
    end
  end

  def get_last_commit_time()
    if self.valid?
      return @r.commits.tip.date.strftime('%F')
    else
      return nil
    end
  end

  def get_version(distro, explicit_version = nil)
    # get remote head
    if explicit_version == 'REMOTE_HEAD'
      return 'default', 'default'
    end

    # get the version if it's a branch
    @r.branches.each() do |branch|
      # get the branch shortname
      branch_name = branch.name

      # save the branch as the version if it matches either the explicit
      # version or the distro name
      if explicit_version
        if branch_name == explicit_version
          return branch.name, branch_name
        end
      elsif branch_name.include? distro
        return branch.name, branch_name
      end
    end

    # get the version if it's a tag
    @r.tags.all.each do |tag|
      tag_name = tag.name

      # save the tag if it matches either the explicit version or the distro name
      if explicit_version
        if tag_name == explicit_version
          return tag.name, tag_name
        end
      elsif tag_name.include? distro
        return tag.name, tag_name
      end
    end

    return nil, nil
  end
end

class SVN < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'svn')

    @r = nil
    @origin = nil

    yconf = {
      'svn_repo_master' => Svn::Core.uri_canonicalize(uri),
      'svn_repo_working_copy' => local_path
    }

    if self.uri_ok?
      if File.exist?(File.join(@local_path,'.svn'))
        @r = SvnWc::RepoAccess.new(YAML::dump(yconf), do_checkout=false, force=false)
        dputs " - opened svn repository at: " << @local_path << " from uri: " << @uri
      else
        begin
          @r = SvnWc::RepoAccess.new(YAML::dump(yconf), do_checkout=true, force=true)
          dputs " - initialized new svn repository at: " << @local_path << " from uri: " << @uri
        rescue
          puts ('ERROR: could not initialize new svn repo from uri: ' + @uri).red
        end
      end
    else
      puts ("ERROR: could not reach hg repository at uri: " + @uri).red
    end
  end

  def valid?()
    return (not @r.nil?)
  end

  def fetch()
    # fetch the remote
    # noop
  end

  def checkout(version)
    if self.valid? and version == 'HEAD'
      dputs " --- checking out " << version.to_s << " uri: " << @uri << " in path: " << @local_path
      #@r.update(version) WTF libsvn supermemleak
      system('cd "'+@local_path+'" svn up -r'+version)
    else
    end
  end

  def get_last_commit_time()
    if self.valid?
      begin
        return @r.info[:last_changed_date].strftime('%F')
      rescue
        puts ('ERROR: could not get last changed date for repo in '+@local_path).red
      end
    end
    return nil
  end

  def get_version(distro, explicit_version = nil)
    # NOTE: for svn we don't support branch discovery because _don't use svn_
    if not explicit_version.nil?
      if explicit_version == 'REMOTE_HEAD'
        return 'HEAD', 'HEAD'
      else
        return explicit_version, explicit_version
      end
    else
      return nil, nil
    end
  end
end

class GITSVN < GIT
  # we hates the subversionses
  # so use git instead!
  # this uses git-svn to clone an svn repo
  def initialize(local_path, uri)
    if self.uri_ok?
      unless File.exist?(@local_path)
        # TODO
        dputs " - opened svn repository at: " << @local_path << " from uri: " << @uri
      else
        # TODO
        dputs " - initialized new svn repository at: " << @local_path << " from uri: " << @uri
      end
    else
      puts ("ERROR: could not reach hg repository at uri: " + @uri).red
    end

    super(local_path, uri)
  end

  def get_version(distro, explicit_version = nil)
    if explicit_version == 'HEAD'
      return super(distro, explicit_version = 'master')
    else
      return nil, nil
    end
  end
end

def get_vcs(repo)

  vcs = nil

  case repo.type
  when 'git'
    dputs "Getting git repo: " + repo.uri.to_s
    vcs = GIT.new(repo.local_path, repo.uri)
  when 'hg'
    dputs "Getting hg repo: " + repo.uri.to_s
    vcs = HG.new(repo.local_path, repo.uri)
  when 'svn'
    dputs "Getting svn repo: " + repo.uri.to_s
    vcs = SVN.new(repo.local_path, repo.uri)
  else
    dputs ("Unsupported VCS type: "+repo.type.to_s).red
  end

  if vcs.valid?
    return vcs
  else
    return nil
  end
end

# Converts RST to Markdown
def rst_to_md(rst)
  return PandocRuby.convert(rst, :from => :rst, :to => :markdown)
end

# Modifies markdown image links so that they link to github user content
def fix_image_links(text, raw_uri, additional_path = '')
  readme_doc = Nokogiri::HTML(text)
  readme_doc.xpath("//img[@src]").each() do |el|
    #puts 'img: '+el['src'].to_s
    unless el['src'].start_with?('http')
      el['src'] = ('%s/%s/' % [raw_uri, additional_path])+el['src']
    end
  end

  return readme_doc.to_s, readme_doc
end

def get_readme(site, path, raw_uri)

  rst_path = File.join(path,'README.rst')
  md_path = File.join(path,'README.md')
  txt_a_path = File.join(path,'README.txt')
  txt_b_path = File.join(path,'README')

  if File.exist?(rst_path)
    readme_rst = IO.read(rst_path)
    readme_md = rst_to_md(readme_rst)
  elsif File.exist?(md_path)
    readme_md = IO.read(md_path)
  elsif File.exist?(txt_a_path)
    readme_txt = IO.read(txt_a_path)
    readme_md = "```\n" + readme_txt + "\n```"
  elsif File.exist?(txt_b_path) and not File.directory?(txt_b_path)
    readme_txt = IO.read(txt_b_path)
    readme_md = "```\n" + readme_txt + "\n```"
  end

  if readme_md
    # read in the readme and fix links
    readme_html = render_md(site, readme_md)
    readme_html = '<div class="rendered-markdown">'+readme_html+"</div>"
    readme_rendered, _ = fix_image_links(readme_html, raw_uri)
  else
    readme_rendered = nil
  end

  return readme_rendered, readme_md
end

def get_changelog(site, path)

  rst_path = File.join(path,'CHANGELOG.rst')
  md_path = File.join(path,'CHANGELOG.md')
  txt_a_path = File.join(path,'CHANGELOG.txt')
  txt_b_path = File.join(path,'CHANGELOG')

  if File.exist?(rst_path)
    changelog_rst = IO.read(rst_path)
    changelog_md = rst_to_md(changelog_rst)
  elsif File.exist?(md_path)
    changelog_md = IO.read(md_path)
  elsif File.exist?(txt_a_path)
    changelog_txt = IO.read(txt_a_path)
    changelog_md = '```\n' + changelog_txt + '\n```'
  elsif File.exist?(txt_b_path)
    changelog_txt = IO.read(txt_b_path)
    changelog_md = '```\n' + changelog_txt + '\n```'
  end

  if changelog_md
    # read in the changelog and fix links
    changelog_html = render_md(site, changelog_md)
    changelog_rendered = '<div class="rendered-markdown">'+changelog_html+"</div>"
  else
    changelog_rendered = nil
  end

  return changelog_rendered, changelog_md
end

# Renders markdown to html (and apply some required tweaks)
def render_md(site, readme)
  begin
    mkconverter = site.getConverterImpl(Jekyll::Converters::Markdown)
    readme.gsub! "```","\n```"
    readme.gsub! '```shell','```bash'
    return mkconverter.convert(readme)
  rescue
    return 'Could not convert readme.'
  end
end

# Get a raw URI from a repo uri
def get_raw_uri(uri_s, branch)
  uri = URI(uri_s)

  case uri.host
  when 'github.com'
    uri_split = File.split(uri.path)
    return 'https://raw.githubusercontent.com/%s/%s/%s' % [uri_split[0], uri_split[1].rpartition('.')[0], branch]
  when 'bitbucket.org'
    uri_split = File.split(uri.path)
    return 'https://bitbucket.org/%s/%s/raw/%s' % [uri_split[0], uri_split[1], branch]
  end

  return ''
end

def get_browse_uri(uri_s, branch)
  uri = URI(uri_s)

  case uri.host
  when 'github.com'
    uri_split = File.split(uri.path)
    return 'https://github.com/%s/%s/blob/%s' % [uri_split[0], uri_split[1].rpartition('.')[0], branch]
  when 'bitbucket.org'
    uri_split = File.split(uri.path)
    return 'https://bitbucket.org/%s/%s/src/%s' % [uri_split[0], uri_split[1], branch]
  end

  return ''
end

def get_id(uri)
  # combines the domain name and path, hyphenated
  p_uri = URI(uri)
  return (p_uri.host.split('.').reject{|v| if v.length < 3 or v == 'com' or v == 'org' or v == 'edu' then v end} + p_uri.path.split(%r{[./]}).reject{|v| if v.length == 0 then true end}[0,2]).join('-')
end

class PackageSnapshot < Liquid::Drop
  # This represents a snapshot of a ROS package found in a repo snapshot
  attr_accessor :name, :repo, :snapshot, :version, :data
  def initialize(name, repo, snapshot, data)
    @name = name

    # TODO: get rid of these back-pointers
    @repo = repo
    @snapshot = snapshot
    @version = snapshot.version

    # additionally-collected data
    @data = data
  end
end

class RepoSnapshot < Liquid::Drop
  # This represents a snapshot of a version control repository
  attr_accessor :released, :distro, :version, :data, :packages
  def initialize(version, distro, released)
    # the version control system version string
    # this is either a branch or tag of the remote repo
    @version = version

    # whether this snapshot is released
    @released = released

    # the distro that this snapshot works with
    @distro = distro

    # metadata about this snapshot
    @data = {}

    # package name -> PackageSnapshot
    # these are all the packages in this repo snapshot
    @packages = {}
  end
end

class Repo < Liquid::Drop
  # This represents a remote repository
  attr_accessor :name, :id, :uri, :purpose, :snapshots, :tags, :type, :status, :local_path, :local_name
  def initialize(name, type, uri, purpose, checkout_path)
    # unique identifier
    @id = get_id(uri)

    # non-unique identifier for this repo
    @name = name

    # the uri for cloning this repo
    @uri = cleanup_uri(uri)

    # the version control system type
    @type = type

    # a brief description of this remote
    @purpose = purpose

    # maintainer status
    @status = nil

    # the local repo name to checkout to (this is important for older rosbuild packages)
    @local_name = name

    # the local path to this repo
    @local_path = File.join(checkout_path, @name, @id, @local_name)

    # hash distro -> RepoSnapshot
    # each entry in this hash represents the preferred version for a given distro in this repo
    @snapshots = Hash[$all_distros.collect { |d| [d, RepoSnapshot.new(nil, d, false)] }]

    # tags from all versions
    @tags = []
  end
end

class RepoInstances < Liquid::Drop
  # This represents a group of repositories with the same name
  attr_accessor :name, :default, :instances
  def initialize(name)
    # identifier for this repo
    @name = name

    # hash instance_id -> Repo
    # these are all of the known instances of this repo
    @instances = {}

    # reference to the preferred Repo instance
    @default = nil
  end
end

class PackageInstances < Liquid::Drop
  # This represents a group of package snapshots with the same name
  attr_accessor :name, :tags, :instances, :snapshots, :repos
  def initialize(name)
    # name of the package
    @name = name

    # tags from all package instances
    @tags = []

    # hash distro -> RepoSnapshot
    # each entry in this hash is the preferred snapshot for this package
    @repos = Hash[$all_distros.collect { |d| [d, nil] }]
    @snapshots = Hash[$all_distros.collect { |d| [d, nil] }]

    # hash instance_id -> Repo
    # each repo in this hash contains the package in question, even if it's not a preferred snapshot
    @instances = {}
  end
end

class RosIndexDB
  attr_accessor :all_repos, :repo_names, :package_names
  def initialize
    # the global index of repos
    @all_repos = Hash.new
    # the list of repo instances by name
    @repo_names = Hash.new
    # the list of package instances by name
    @package_names = Hash.new

    self.add_procs
  end

  def add_procs
    @repo_names.default_proc = proc do |h, k|
      h[k]=RepoInstances.new(k)
    end

    @package_names.default_proc = proc do |h, k|
      h[k]=PackageInstances.new(k)
    end
  end

  def marshal_dump
    [Hash[@all_repos], Hash[@repo_names], Hash[@package_names]]
  end

  def marshal_load array
    @all_repos, @repo_names, @package_names = array
    self.add_procs
  end
end

class GitScraper < Jekyll::Generator
  def initialize(config = {})
    super(config)

    # lunr search config
    lunr_config = {
      'excludes' => [],
      'strip_index_html' => false,
      'min_length' => 3,
      'stopwords' => '_stopwords/stop-words-english1.txt'
    }.merge!(config['lunr_search'] || {})
    # lunr excluded files
    @excludes = lunr_config['excludes']
    # if web host supports index.html as default doc, then optionally exclude it from the url
    @strip_index_html = lunr_config['strip_index_html']
    # stop word exclusion configuration
    @min_length = lunr_config['min_length']
    @stopwords_file = lunr_config['stopwords']
    if File.exists?(@stopwords_file)
      @stopwords = IO.readlines(@stopwords_file).map { |l| l.strip }
    else
      @stopwords = []
    end
  end

  def update_local(site, repo_instances)

    puts "Updating repo for "+repo_instances.name

    # add / fetch all the instances
    repo_instances.instances.each do |id, repo|

      puts "Updating repo instance "+repo.id

      # open or initialize this repo
      local_path = File.join(@checkout_path, repo_instances.name, id)

      # make sure there's an actual uri
      unless repo.uri
        puts ("WARNING: No URI for " + id).yellow
        next
      end

      if @domain_blacklist.include? URI(repo.uri).hostname
        puts ("ERROR: Repo instance " + id + " has a blacklisted hostname: " + repo.uri.to_s).red
        next
      end

      # open or create a repo
      vcs = get_vcs(repo)
      unless (not vcs.nil? and vcs.valid?) then next end

      # fetch the repo
      vcs.fetch()
    end
  end

  def find_packages(site, distro, data, local_path)

    packages = {}

    # find packages in this branch
    Find.find(local_path) do |path|
      if FileTest.directory?(path)
        # skip certain paths
        if (File.basename(path)[0] == ?.) or File.exist?(File.join(path,'CATKIN_IGNORE')) or File.exist?(File.join(path,'.rosindex_ignore')) 
          Find.prune
        end

        # check for package.xml in this directory
        package_xml_path = File.join(path,'package.xml')
        manifest_xml_path = File.join(path,'manifest.xml')
        stack_xml_path = File.join(path,'stack.xml')

        if File.exist?(package_xml_path)
          manifest_xml = IO.read(package_xml_path)
          pkg_type = 'catkin'

          # read the package manifest
          manifest_doc = REXML::Document.new(manifest_xml)
          package_name = REXML::XPath.first(manifest_doc, "/package/name/text()").to_s.rstrip.lstrip
          version = REXML::XPath.first(manifest_doc, "/package/version/text()").to_s

          # get dependencies
          deps = REXML::XPath.each(manifest_doc, "/package/build_depend/text() | /package/run_depend/text() | package/depend/text()").map { |a| a.to_s }.uniq

        elsif File.exist?(manifest_xml_path)
          manifest_xml = IO.read(manifest_xml_path)
          pkg_type = 'rosbuild'

          # check for a stack.xml file
          if File.exist?(stack_xml_path)
            stack_xml = IO.read(stack_xml_path)
            stack_doc = REXML::Document.new(stack_xml)
            package_name = REXML::XPath.first(stack_doc, "/stack/name/text()").to_s
            if package_name.length == 0
              package_name = File.basename(File.join(path))
            end
            version = REXML::XPath.first(stack_doc, "/stack/version/text()").to_s
          else
            package_name = File.basename(File.join(path))
            version = "UNKNOWN"
          end

          # read the package manifest
          manifest_doc = REXML::Document.new(manifest_xml)

          # get dependencies
          deps = REXML::XPath.each(manifest_doc, "/package/depend/@package").map { |a| a.to_s }.uniq
        else
          next
        end

        puts " ---- Found #{pkg_type} package \"#{package_name}\" in path #{path}"

        # extract manifest metadata (same for manifest.xml and package.xml)
        license = REXML::XPath.first(manifest_doc, "/package/license/text()").to_s
        description = REXML::XPath.first(manifest_doc, "/package/description/text()").to_s
        maintainers = REXML::XPath.each(manifest_doc, "/package/maintainer/text()").map { |m| m.to_s.sub('@', ' <AT> ') }
        authors = REXML::XPath.each(manifest_doc, "/package/author/text()").map { |a| a.to_s.sub('@', ' <AT> ') }

        # extract rosindex exports
        tags = REXML::XPath.each(manifest_doc, "/package/export/rosindex/tags/tag/text()").map { |t| t.to_s }

        # compute the relative path from the root of the repo to this directory
        relpath = Pathname.new(File.join(*path)).relative_path_from(Pathname.new(local_path))
        local_package_path = Pathname.new(path)

        # extract package manifest info
        raw_uri = File.join(data['raw_uri'], relpath)
        browse_uri = File.join(data['browse_uri'], relpath)

        # check for readme in same directory as package.xml
        readme_rendered, readme = get_readme(site, path, raw_uri)
        changelog_rendered, changelog = get_changelog(site, path)

        # TODO
        # look for launchfiles in this package
        launch_files = Dir[File.join(path,'**','*.launch')]
        # look for message files in this package
        msg_files = Dir[File.join(path,'**','*.msg')]
        # look for service files in this package
        srv_files = Dir[File.join(path,'**','*.srv')]
        # look for plugin descriptions in this package
        # TODO: get plugin files from <exports> tag

        package_info = {
          'name' => package_name,
          'pkg_type' => pkg_type,
          'distro' => distro,
          'raw_uri' => raw_uri,
          'browse_uri' => browse_uri,
          # required package info
          'name' => package_name,
          'version' => version,
          'license' => license,
          'description' => description,
          'maintainers' => maintainers,
          # optional package info
          'authors' => authors,
          # dependencies
          'deps' => deps,
          # rosindex metadata
          'tags' => tags,
          # readme
          'readme' => readme,
          'readme_rendered' => readme_rendered,
          # changelog
          'changelog' => changelog,
          'changelog_rendered' => changelog_rendered,
          # assets
          'launch_files' => launch_files.map {|f| Pathname.new(f).relative_path_from(local_package_path).to_s },
          'msg_files' => msg_files.map {|f| Pathname.new(f).relative_path_from(local_package_path).to_s },
          'srv_files' => srv_files.map {|f| Pathname.new(f).relative_path_from(local_package_path).to_s }
        }

        dputs " -- adding package " << package_name
        packages[package_name] = package_info

        # stop searching a directory after finding a package
        Find.prune
      end
    end

    return packages
  end

  # scrape a version of a repository for packages and their contents
  def scrape_version(site, repo, distro, snapshot, vcs)

    unless repo.uri
      puts ("WARNING: no URI for "+repo.name+" "+repo.id+" "+distro).yellow
      return
    end

    # initialize this snapshot data
    data = snapshot.data = {
      # get the uri for resolving raw links (for imgages, etc)
      'raw_uri' => get_raw_uri(repo.uri, snapshot.version),
      'browse_uri' => get_browse_uri(repo.uri, snapshot.version),
      # get the date of the last modification
      'last_commit_time' => vcs.get_last_commit_time(),
      'readme' => nil,
      'readme_rendered' => nil}

    # load the repo readme for this branch if it exists
    data['readme_rendered'], data['readme'] = get_readme(
      site,
      vcs.local_path,
      data['raw_uri'])

    # get all packages from the repo
    packages = find_packages(site, distro, snapshot.data, vcs.local_path)

    # add the discovered packages to the index
    packages.each do |package_name, package_data|
      # create a new package snapshot
      package = PackageSnapshot.new(package_name, repo, snapshot, package_data)

      # store this package in the repo snapshot
      snapshot.packages[package_name] = package

      # collect tags from discovered packages
      repo.tags = Set.new(repo.tags).merge(package_data['tags']).to_a

      # add this package to the global package dict
      @package_names[package_name].instances[repo.id] = repo
      @package_names[package_name].tags = Set.new(@package_names[package_name].tags).merge(package_data['tags']).to_a

      # add this package as the default for this distro
      if @repo_names[repo.name].default
        dputs " --- Setting repo instance " << repo.id << "as default for package " << package_name << " in distro " << distro
        @package_names[package_name].repos[distro] = repo
        @package_names[package_name].snapshots[distro] =  package
      end
    end
  end

  def scrape_repo(site, repo)

    if @domain_blacklist.include? URI(repo.uri).hostname
      puts ("ERROR: Repo instance " + repo.id + " has a blacklisted hostname: " + repo.uri.to_s).red
      return
    end

    # open or initialize this repo
    vcs = get_vcs(repo)
    unless (not vcs.nil? and vcs.valid?) then return end

    # get versions suitable for checkout for each distro
    repo.snapshots.each do |distro, snapshot|

      # get explicit version (this is either set or nil)
      explicit_version = snapshot.version

      if explicit_version.nil?
        dputs " -- no explicit version for distro " << distro << " looking for implicit version "
      else
        dputs " -- looking for version " << explicit_version.to_s << " for distro " << distro
      end

      # get the version
      version, snapshot.version = vcs.get_version(distro, explicit_version)

      # scrape the data (packages etc)
      if version
        puts (" --- scraping version for " << repo.name << " instance: " << repo.id << " distro: " << distro).blue

        # check out this branch
        vcs.checkout(version)

        # check for ignore file
        if  File.exist?(File.join(vcs.local_path,'.rosindex_ignore')) 
          puts (" --- ignoring version for " << repo.name).yellow
          snapshot.version = nil
        else
          scrape_version(site, repo, distro, snapshot, vcs)
        end
      else
        puts (" --- no version for " << repo.name << " instance: " << repo.id << " distro: " << distro).yellow
      end
    end

  end

  def generate(site)

    # create the checkout path if necessary
    @checkout_path = site.config['checkout_path']
    puts "checkout path: " + @checkout_path
    unless File.exist?(@checkout_path)
      FileUtils.mkpath(@checkout_path)
    end

    # construct list of known ros distros
    $recent_distros = site.config['distros']
    $all_distros = site.config['distros'] + site.config['old_distros']

    @domain_blacklist = site.config['domain_blacklist']

    @db_filename = if site.config['cache_filename'] then File.join(site.source,site.config['cache_filename']) else 'rosindex.db' end
    @use_cached = (site.config['use_cached'] and File.exist?(@db_filename))

    if @use_cached
      @db = Marshal.load(IO.read(@db_filename))
    else
      @db = RosIndexDB.new
    end

    # the global index of repos
    @all_repos = @db.all_repos
    # the list of repo instances by name
    @repo_names = @db.repo_names
    # the list of package instances by name
    @package_names = @db.package_names

    unless @use_cached

      # get the repositories from the rosdistro files
      $all_distros.each do |distro|

        puts "processing rosdistro: "+distro

        # read in the rosdistro distribution file
        rosdistro_filename = File.join(site.config['rosdistro_path'],distro,'distribution.yaml')
        if File.exist?(rosdistro_filename)
          distro_data = YAML.load_file(rosdistro_filename)
          distro_data['repositories'].each do |repo_name, repo_data|

            # limit repos if requested
            if not @repo_names.has_key?(repo_name) and site.config['max_repos'] > 0 and @repo_names.length > site.config['max_repos'] then next end

            puts " - "+repo_name

            source_uri = nil
            source_version = nil
            source_type = nil

            # only index if it has a source repo
            if repo_data.has_key?('source')
              source_uri = repo_data['source']['url'].to_s
              source_type = repo_data['source']['type'].to_s
              source_version = repo_data['source']['version'].to_s
            elsif repo_data.has_key?('doc')
              source_uri = repo_data['doc']['url'].to_s
              source_type = repo_data['doc']['type'].to_s
              source_version = repo_data['doc']['version'].to_s
            elsif repo_data.has_key?('release')
              # TODO: get the release repo to get the upstream repo
              # NOTE: also, sometimes people use the release repo as the "doc" repo
              puts ("ERROR: No source or doc information for repo: " + repo_name + " in rosidstro file: " + rosdistro_filename).red
              next
            else
              puts ("ERROR: No source, doc, or release information for repo: " + repo_name+ " in rosidstro file: " + rosdistro_filename).red
              next
            end

            # create a new repo structure for this remote
            repo = Repo.new(
              repo_name,
              source_type,
              source_uri,
              'Via rosdistro: '+distro,
              @checkout_path)

            # get maintainer status
            if repo_data.key?('status')
              repo.status = repo_data['status']
            end

            if @all_repos.key?(repo.id)
              repo = @all_repos[repo.id]
            else
              dputs " -- Adding repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s
              # store this repo in the unique index
              @all_repos[repo.id] = repo
            end

            # add the specific version from this instance
            repo.snapshots[distro] = RepoSnapshot.new(source_version, distro, repo_data.key?('release'))

            # store this repo in the name index
            @repo_names[repo.name].instances[repo.id] = repo
            @repo_names[repo.name].default = repo
          end
        end

        # read in the old documentation index file (if it exists)
        doc_path = File.join(site.config['rosdistro_path'],'doc',distro)

        puts "Examining doc path: " << doc_path

        Dir.glob(File.join(doc_path,'*.rosinstall')) do |rosinstall_filename|
          puts 'Indexing rosinstall repo data file: ' << rosinstall_filename
          rosinstall_data = YAML.load_file(rosinstall_filename)
          rosinstall_data.each do |rosinstall_entry|
            rosinstall_entry.each do |repo_type, repo_data|

              if repo_data.nil? then next end
              if repo_type == 'bzr'
                puts ("ERROR: some fools trying to use bazaar: " + rosinstall_filename).red
                next
              end

              #puts repo_type.inspect
              #puts repo_data.inspect

              # extract the garbage
              repo_name = repo_data['local-name'].to_s
              repo_uri = repo_data['uri'].to_s
              repo_version = if repo_data.key?('version') then repo_data['version'].to_s else 'REMOTE_HEAD' end

              # limit number of repos indexed if in devel mode
              if not @repo_names.has_key?(repo_name) and site.config['max_repos'] > 0 and @repo_names.length > site.config['max_repos'] then next end

              # create a new repo structure for this remote
              repo = Repo.new(
                repo_name,
                repo_type,
                repo_uri,
                'Via rosdistro doc: '+distro,
                @checkout_path)

              if @all_repos.key?(repo.id)
                repo = @all_repos[repo.id]
              else
                dputs " -- Adding repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s
                # store this repo in the unique index
                @all_repos[repo.id] = repo
              end

              # add the specific version from this instance
              repo.snapshots[distro] = RepoSnapshot.new(repo_version, distro, false)

              # store this repo in the name index
              @repo_names[repo.name].instances[repo.id] = repo
              if @repo_names[repo.name].default.nil?
                @repo_names[repo.name].default = repo
              end
            end
          end
        end
      end

      # add additional repo instances to the main dict
      Dir.glob(File.join(site.config['repos_path'],'*.yaml')) do |repo_filename|

        # limit repos if requested
        #if site.config['max_repos'] > 0 and @all_repos.length > site.config['max_repos'] then break end

        # read in the repo data
        repo_name = File.basename(repo_filename, File.extname(repo_filename)).to_s
        repo_data = YAML.load_file(repo_filename)

        puts " - Adding repositories for " << repo_name

        # add all the instances
        repo_data['instances'].each do |instance|

          # create a new repo structure for this remote
          repo = Repo.new(
            repo_name,
            instance['type'],
            instance['uri'],
            instance['purpose'],
            @checkout_path)

          uri = repo.uri

          dputs " -- Added repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s

          # add distro versions for instance
          $all_distros.each do |distro|

            # get the explicit version identifier for this distro
            explicit_version = if instance.key?('distros') and instance['distros'].key?(distro) and instance['distros'][distro].key?('version') then instance['distros'][distro]['version'] else nil end

            # add the specific version from this instance
            repo.snapshots[distro].version = explicit_version
            repo.snapshots[distro].released = false
          end

          # store this repo in the unique index
          @all_repos[repo.id] = repo

          # store this repo in the name index
          @repo_names[repo.name].instances[repo.id] = repo
          if instance['default'] or @repo_names[repo.name].default.nil?
            @repo_names[repo.name].default = repo
          end
        end
      end

      puts "Found " << @all_repos.length.to_s << " repositories corresponding to " << @repo_names.length.to_s << " repo identifiers."

      # clone / fetch all the repos
      work_q = Queue.new
      @repo_names.each {|r| work_q.push r}
      puts "Fetching sources with " << site.config['checkout_threads'].to_s << " threads."
      workers = (0...site.config['checkout_threads']).map do
        Thread.new do
          begin
            while ri = work_q.pop(true)
              update_local(site, ri[1])
            end
          rescue ThreadError
          end
        end
      end; "ok"
      workers.map(&:join); "ok"

      # scrape all the repos
      puts "Scraping known repos..."
      @all_repos.each do |repo_id, repo|
        puts "Scraping " << repo.id << "..."
        scrape_repo(site, repo)
      end

      # save scraped data
      File.open(@db_filename, 'w') {|f| f.write(Marshal.dump(@db)) }
    end

    # generate pages for all repos
    @repo_names.each do |repo_name, repo_instances|

      # create the repo pages
      puts " - creating pages for repo "+repo_name+"..."

      # create a list of instances for this repo
      site.pages << RepoInstancesPage.new(site, repo_instances)

      # create the page for the default instance
      site.pages << RepoPage.new(site, repo_instances, repo_instances.default, true)

      # create pages for each repo instance
      repo_instances.instances.each do |instance_id, instance|
        site.pages << RepoPage.new(site, repo_instances, instance, false)
      end
    end

    # create package pages
    puts "Found "+String(@package_names.length)+" packages total."

    @package_names.each do |package_name, package_instances|

      puts "Generating pages for package " << package_name << "..."

      # create default package page
      site.pages << PackagePage.new(site, package_instances)

      # create package page which lists all the instances
      site.pages << PackageInstancesPage.new(site, package_instances)

      # create a page for each package instance
      package_instances.instances.each do |instance_id, instance|
        puts "Generating page for package " << package_name << " instance " << instance_id << "..."
        site.pages << PackageInstancePage.new(site, package_instances, instance, package_name)
      end
    end

    # create repo list pages
    repos_per_page = site.config['repos_per_page']
    n_repo_list_pages = (@repo_names.length / repos_per_page).ceil + 1

    repos_alpha = @repo_names.sort_by { |name, instances| name }
    repos_time = repos_alpha.reverse.sort_by { |name, instances| (instances.default.snapshots.reject { |d,s| not $recent_distros.include?(d) }.map {|d,s| s.data['last_commit_time'].to_s}).max }.reverse
    repos_doc = repos_alpha.reverse.sort_by { |name, instances| -(instances.default.snapshots.count {|d,s| $recent_distros.include?(d) and not s.data['readme_rendered'].nil? }) }
    repos_released = repos_alpha.reverse.sort_by { |name, instances| -(instances.default.snapshots.count {|d,s| $recent_distros.include?(d) and s.released}) }

    (1..n_repo_list_pages).each do |page_index|

      p_start = (page_index-1) * repos_per_page
      p_end = [@repo_names.length, p_start+repos_per_page].min

      list_alpha = repos_alpha.slice(p_start, repos_per_page)
      list_time = repos_time.slice(p_start, repos_per_page)
      list_doc = repos_doc.slice(p_start, repos_per_page)
      list_released = repos_released.slice(p_start, repos_per_page)

      # create alpha pages
      site.pages << RepoListPage.new( site, '', n_repo_list_pages, page_index, list_alpha)
      if page_index == 1
        site.pages << RepoListPage.new( site, '', n_repo_list_pages, page_index, list_alpha, true)
      end

      site.pages << RepoListPage.new( site, 'time', n_repo_list_pages, page_index, list_time)
      site.pages << RepoListPage.new( site, 'doc', n_repo_list_pages, page_index, list_doc)
      site.pages << RepoListPage.new( site, 'released', n_repo_list_pages, page_index, list_released)
    end

    # create package list pages
    packages_per_page = site.config['packages_per_page']
    n_package_list_pages = (@package_names.length / packages_per_page).ceil + 1

    packages_alpha = @package_names.sort_by { |name, instances| name }

    packages_time = packages_alpha.reverse.sort_by { |name, instances| 
      instances.snapshots.reject { |d,s|
        s.nil? or not $recent_distros.include?(d)}.map { |d,s|
          s.snapshot.data['last_commit_time'].to_s}.max.to_s }.reverse

    packages_doc = packages_alpha.reverse.sort_by { |name, instances| 
      -(instances.snapshots.count {|d,s| 
        not s.nil? and $recent_distros.include?(d) and not s.data['readme_rendered'].nil? }) }

    packages_released = packages_alpha.reverse.sort_by { 
      |name, instances| -(instances.snapshots.count { |d,s| 
        not s.nil? and $recent_distros.include?(d) and s.snapshot.released}) }

    (1..n_package_list_pages).each do |page_index|

      p_start = (page_index-1) * packages_per_page
      p_end = [@package_names.length, p_start+packages_per_page].min

      list_alpha = packages_alpha.slice(p_start, packages_per_page)
      list_time = packages_time.slice(p_start, packages_per_page)
      list_doc = packages_doc.slice(p_start, packages_per_page)
      list_released = packages_released.slice(p_start, packages_per_page)

      site.pages << PackageListPage.new(site, '', n_package_list_pages, page_index, list_alpha)
      if page_index == 1
        site.pages << PackageListPage.new(site, '', n_package_list_pages, page_index, list_alpha, true)
      end

      site.pages << PackageListPage.new( site, 'time', n_package_list_pages, page_index, list_time)
      site.pages << PackageListPage.new( site, 'doc', n_package_list_pages, page_index, list_doc)
      site.pages << PackageListPage.new( site, 'released', n_package_list_pages, page_index, list_released)
    end

    # create lunr index data
    index = []
    @all_repos.each do |instance_id, repo|
      repo.snapshots.each do |distro, repo_snapshot|

        if repo_snapshot.version == nil then next end

        repo_snapshot.packages.each do |package_name, package|

          if package.nil? then next end

          p = package.data

          readme_filtered = if p['readme'] then self.strip_stopwords(p['readme']) else "" end

          index << {
            'id' => index.length,
            'baseurl' => site.config['baseurl'],
            'url' => File.join('/p',package_name,instance_id)+"#"+distro,
            'last_commit_time' => repo_snapshot.data['last_commit_time'],
            'tags' => p['tags'] * " ",
            'name' => package_name,
            'repo_name' => repo.name,
            'released' => if repo_snapshot.released then 'is:released' else '' end,
            'unreleased' => if repo_snapshot.released then 'is:unreleased' else '' end,
            'version' => p['version'],
            'description' => p['description'],
            'maintainers' => p['maintainers'] * " ",
            'authors' => p['authors'] * " ",
            'distro' => distro,
            'instance' => repo.id,
            'readme' => readme_filtered
          }

          puts 'indexed: ' << "#{package_name} #{instance_id} #{distro}"
        end
      end
    end

    # generate index in the json format needed by lunr
    index_json = JSON.generate({'entries'=>index})

    # save the json file
    # TODO: is there no way to do this in fewer lines?
    Dir::mkdir(site.dest) unless File.directory?(site.dest)
    index_filename = 'search.json'

    File.open(File.join(site.dest, index_filename), "w") do |index_file|
      index_file.write(index_json)
    end

    # add this file as a static site file
    site.static_files << SearchIndexFile.new(site, site.dest, "/", index_filename)

    # precompute the lunr index
    lunr_cmd = File.join(site.source,'node_modules','lunr-index-build','bin','lunr-index-build')
    lunr_index_fields = [
      '-r','id',
      '-f','baseurl',
      '-f','instance',
      '-f','url',
      '-f','tags:100',
      '-f','name:100',
      '-f','version',
      '-f','description:50',
      '-f','maintainers',
      '-f','authors',
      '-f','distro',
      '-f','readme',
      '-f','released',
      '-f','unreleased'
    ].join(' ')


    puts ("Precompiling lunr index...").blue
    spawn(
      "#{lunr_cmd} #{lunr_index_fields}",
      :in=>File.join(site.dest,index_filename),
      :out=>[File.join(site.dest,'index.json'),"w"])

    site.static_files << SearchIndexFile.new(site, site.dest, "/", "index.json")

    # create stats page
    site.pages << StatsPage.new(site, @package_names, @all_repos)
  end

  def strip_stopwords(text)
    text = text.split.delete_if() do |x|
      t = x.downcase.gsub(/[^a-z']/, '')
      t.length < @min_length || @stopwords.include?(t)
    end.join(' ')
  end
end

def get_available_distros(site, versions_dict)
  # create easy-to-process lists of available distros for the switcher

  available_distros = {}
  available_older_distros = {}

  site.config['distros'].each do |distro|
    available_distros[distro] = (versions_dict[distro] != nil and versions_dict[distro].version != nil)
  end

  site.config['old_distros'].each do |distro|
    available_older_distros[distro] = (versions_dict[distro] != nil and versions_dict[distro].version != nil)
  end

  return available_distros, available_older_distros, available_older_distros.values.count(true)
end

class RepoInstancesPage < Jekyll::Page
  def initialize(site, repo_instances)
    @site = site
    @base = site.source
    @dir = File.join('repos', repo_instances.name)
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repo_instances.html')
    self.data['repo_instances'] = repo_instances
  end
end


class RepoPage < Jekyll::Page
  def initialize(site, instances, repo, default)

    basepath = File.join('r', repo.name)

    @site = site
    @base = site.source
    @dir = if default then basepath else File.join(basepath, repo.id) end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repo_instance.html')

    self.data['instance'] =   repo
    self.data['repo'] =   repo

    self.data['instances'] = instances.instances
    self.data['instance_base_url'] = basepath
    self.data['instance_index_url'] = File.join('repos', repo.name)
    self.data['default_instance_id'] = instances.default.id

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, repo.snapshots)

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class PackageListPage < Jekyll::Page
  def initialize(site, sort_id, n_list_pages, page_index, list_alpha, default=false)
    @site = site
    @base = site.source
    @dir = unless default then 'packages/page/'+page_index.to_s+'/'+sort_id else 'packages' end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'packages.html')
    self.data['pager'] = {
      'base' => 'packages',
      'post_ns' => '/'+sort_id
    }
    self.data['sort_id'] = sort_id
    self.data['n_list_pages'] = n_list_pages
    self.data['page_index'] = page_index
    self.data['list_alpha'] = list_alpha

    self.data['prev_page'] = [page_index - 1, 1].max
    self.data['next_page'] = [page_index + 1, n_list_pages].min

    self.data['near_pages'] = *([1,page_index-4].max..[page_index+4, n_list_pages].min)
    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']

    self.data['available_distros'] = Hash[site.config['distros'].collect { |d| [d, true] }]
    self.data['available_older_distros'] = Hash[site.config['old_distros'].collect { |d| [d, true] }]
    self.data['n_available_older_distros'] = site.config['old_distros'].length
  end
end

class RepoListPage < Jekyll::Page
  def initialize(site, sort_id, n_list_pages, page_index, list_alpha, default=false)
    @site = site
    @base = site.source
    @dir = unless default then 'repos/page/'+page_index.to_s+'/'+sort_id else 'repos' end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repos.html')
    self.data['pager'] = {
      'base' => 'repos',
      'post_ns' => '/'+sort_id
    }
    self.data['sort_id'] = sort_id
    self.data['n_list_pages'] = n_list_pages
    self.data['page_index'] = page_index
    self.data['list_alpha'] = list_alpha

    self.data['prev_page'] = [page_index - 1, 1].max
    self.data['next_page'] = [page_index + 1, n_list_pages].min

    self.data['near_pages'] = *([1,page_index-4].max..[page_index+4, n_list_pages].min)
    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']

    self.data['available_distros'] = Hash[site.config['distros'].collect { |d| [d, true] }]
    self.data['available_older_distros'] = Hash[site.config['old_distros'].collect { |d| [d, true] }]
    self.data['n_available_older_distros'] = site.config['old_distros'].length
  end
end

class PackagePage < Jekyll::Page
  def initialize(site, package_instances)
    @site = site
    @base = site.source
    @dir = File.join('p',package_instances.name)
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package.html')
    self.data['package_instances'] = package_instances
    self.data['package_name'] = package_instances.name

    self.data['instances'] = package_instances.instances

    self.data['instance_index_url'] = File.join('packages',package_instances.name)
    self.data['instance_base_url'] = @dir

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, package_instances.snapshots)

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class PackageInstancesPage < Jekyll::Page
  def initialize(site, package_instances)
    @site = site
    @base = site.source
    @dir = File.join('packages',package_instances.name)
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package_instances.html')
    self.data['package_instances'] = package_instances
    self.data['package_name'] = package_instances.name
  end
end

class PackageInstancePage < Jekyll::Page
  def initialize(site, package_instances, instance, package_name)

    @site = site
    @base = site.source
    @dir = File.join('p', package_name, instance.id)
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package_instance.html')

    self.data['instances'] = package_instances.instances
    self.data['instance'] = instance
    self.data['package_name'] = package_name

    self.data['instance_index_url'] = ['packages',package_instances.name].join('/')
    self.data['instance_base_url'] = ['p',package_name].join('/')

    self.data['available_distros'] = {}
    self.data['available_older_distros'] = {}
    instance.snapshots.each do |distro, snapshot|
      if site.config['distros'].include? distro
        self.data['available_distros'][distro] = snapshot.packages.key?(package_name)
      else
        self.data['available_older_distros'][distro] = snapshot.packages.key?(package_name)
      end
    end
    self.data['n_available_older_distros'] = self.data['available_older_distros'].values.count(true)

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class StatsPage < Jekyll::Page
  def initialize(site, package_names, all_repos)

    @site = site
    @base = site.source
    @dir = 'stats'
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'stats.html')

    # compute venn diagram model
    distro_counts = Hash[$all_distros.collect { |d| [d, 0] }]
    distro_overlaps = Hash[(2..$all_distros.length).flat_map{|n| (0..$all_distros.length-1).to_a.combination(n).to_a}.collect { |s| [s, 0] }]

    package_names.each do |package_name, package_instances|
      overlap = []
      #package_instances.snapshots.reject.with_index{|dr, i| dr[1].nil? || dr[1].version.nil? }
      package_instances.snapshots.each.with_index do |s,i|
        if not s[1].nil? and not s[1].version.nil?
          overlap << i
          distro_counts[s[0]] = distro_counts[s[0]] + 1
        end
      end

      dputs package_name.to_s + " " + overlap.to_s

      package_overlaps = (2..$all_distros.length).flat_map{|n| overlap.combination(n).to_a}

      package_overlaps.each do |o|
        distro_overlaps[o] = distro_overlaps[o] + 1
      end
    end

    self.data['distro_counts'] = distro_counts
    self.data['distro_overlaps'] = Hash[distro_overlaps.collect{|s,c| [s.inspect, c]}]

    # generate date-histogram data
    self.data['distro_activity'] = {}
    now = DateTime.now
    $all_distros.each do |distro|
      activity = []
      all_repos.each do |id, repo|
        if repo.snapshots[distro].data['last_commit_time'].nil? then next end
        activity << (now - DateTime.parse(repo.snapshots[distro].data['last_commit_time'])).to_f
      end
      self.data['distro_activity'][distro] = activity
    end
  end
end

class SearchIndexFile < Jekyll::StaticFile
  # Override write as the search.json index file has already been created
  def write(dest)
    true
  end
end

