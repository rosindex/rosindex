
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

$fetched_uris = {}

class AnomalyLogger
  @@anomalies = []

  def record(repo, snapshot, message)
    @@anomalies << {'repo' => repo, 'snapshot' => snapshot, 'message' => message}
  end
end

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
    if resp.code == 404
      puts ("ERROR: Code "+resp.code.to_s+" bad URI: " + @uri).red
      return false
    elsif resp.timed_out?
      puts ("ERROR: Timed out URI: " + @uri).red
      return false
    end
    return true
  end
end

class GIT < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'git')

    @r = nil
    @origin = nil

    if File.exist?(@local_path)
      @r = Rugged::Repository.new(@local_path)
      puts " - opened git repository at: " << @local_path << " from uri: " << @uri
    else
      @r = Rugged::Repository.init_at(@local_path)
      puts " - initialized new git repository at: " << @local_path << " from uri: " << @uri
    end

    @origin = @r.remotes['origin']

    if @origin.nil? and self.uri_ok?
      puts " - adding remote for " << @uri << " to " << @local_path
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
        puts " - fetching remote from: " + @uri
        @r.fetch(@origin)
      else
        puts " - not fetching remote "
      end
      # this is no longer useful now that repos are all independent on disk
      #$fetched_uris[@uri] = true
    end
  end

  def checkout(version)
    begin
      puts " --- checking out " << version.name.to_s << " from remote: " << version.remote_name.to_s << " uri: " << @uri
      @r.checkout(version)
    rescue
      puts " --- resetting hard to " << version.name.to_s
      @r.reset(version.name, :hard)
    end
  end

  def get_last_commit_time()
    return @r.last_commit.time.strftime('%F')
  end

  def get_version(distro, explicit_version = nil)
    # get the version if it's a branch
    @r.branches.each() do |branch|
      # get the branch shortname
      branch_name = branch.name.split('/')[-1]

      # detached branches are those checked out by the system but not given names
      if branch.name.include? 'detached' then next end
      if branch.remote_name != 'origin' then next end

      # NOTE: no longer need to check remote names #if branch.remote_name != repo.id then next end

      #puts " -- examining branch " << branch.name << " trunc: " << branch_name << " from remote: " << branch.remote_name
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
      if File.exist?(@local_path)
        @r = Mercurial::Repository.open(@local_path)
        puts " - opened hg repository at: " << @local_path << " from uri: " << @uri
      else
        @r = Mercurial::Repository.clone(@uri, @local_path, {})
        puts " - initialized new hg repository at: " << @local_path << " from uri: " << @uri
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
      puts " --- checking out " << version.to_s << " uri: " << @uri
      @r.shell.hg(['update ?', version.name])
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
    # get the version if it's a branch
    @r.branches.each() do |branch|
      # get the branch shortname
      branch_name = branch.name

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
    @r.tags.all.each do |tag|
      tag_name = tag.name

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

class SVN < VCS
  def initialize(local_path, uri)
    super(local_path, uri, 'svn')

    @r = nil
    @origin = nil

    yconf = {
      'svn_repo_master' => uri,
      'svn_repo_working_copy' => local_path 
    }

    if self.uri_ok?
      if File.exist?(@local_path)
        @r = SvnWc::RepoAccess.new(YAML::dump(yconf), do_checkout=false, force=false)
        puts " - opened svn repository at: " << @local_path << " from uri: " << @uri
      else
        @r = SvnWc::RepoAccess.new(YAML::dump(yconf), do_checkout=true, force=true)
        puts " - initialized new svn repository at: " << @local_path << " from uri: " << @uri
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
      puts " --- checking out " << version.to_s << " uri: " << @uri
      @r.update()
    else
    end
  end

  def get_last_commit_time()
    if self.valid?
      return @r.info[:last_changed_date].strftime('%F')
    else
      return nil
    end
  end

  def get_version(distro, explicit_version = nil)
    # NOTE: for svn we don't support branch discovery because _don't use svn_
    if explicit_version == 'HEAD'
      return 'HEAD', 'HEAD'
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
        puts " - opened svn repository at: " << @local_path << " from uri: " << @uri
      else
        # TODO
        puts " - initialized new svn repository at: " << @local_path << " from uri: " << @uri
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


def get_vcs(local_path, uri, vcs_type=nil)

  vcs = nil

  case vcs_type
  when 'git'
    puts "Getting git repo"
    vcs = GIT.new(local_path, uri)
  when 'hg'
    puts "Getting hg repo"
    vcs = HG.new(local_path, uri)
  when 'svn'
    puts "Getting svn repo"
    vcs =  SVN.new(local_path, uri)
  else
    puts ("Unsupported VCS type: "+vcs.to_s).red
  end

  if vcs.valid?
    return vcs
  else
    return nil
  end
end

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

  if File.exist?(rst_path)
    readme_rst = IO.read(rst_path)
    readme_md = rst_to_md(readme_rst)
  elsif File.exist?(md_path)
    readme_md = IO.read(md_path)
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
    return 'https://raw.githubusercontent.com/%s/%s/%s' % [uri_split[0], uri_split[1], branch]
  end

  return ''
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

def get_id(uri)
  # combines the domain name and path, hyphenated
  p_uri = URI(uri)
  return (p_uri.host.split('.').reject{|v| if v.length < 3 or v == 'com' or v == 'org' or v == 'edu' then v end} + p_uri.path.split(%r{[./]}).reject{|v| if v.length == 0 then true end}[0,2]).join('-')
end

class Repo < Liquid::Drop
  # This represents a remote repository
  attr_accessor :name, :id, :uri, :purpose, :snapshots, :tags, :type
  def initialize(id, name, type, uri, purpose)
    # unique identifier
    @id = id

    # non-unique identifier for this repo
    @name = name

    # the uri for cloning this repo
    @uri = uri

    # the version control system type
    @type = type

    # a brief description of this remote
    @purpose = purpose

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
      local_path = File.join(site.config['checkout_path'], repo_instances.name, id)

      # make sure there's an actual uri
      unless repo.uri
        puts ("WARNING: No URI for " + id).yellow
        next
      end

      # open or create a repo
      vcs = get_vcs(local_path, repo.uri, repo.type)
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
        if File.basename(path)[0] == ?. or File.exist?(File.join(path,'CATKIN_IGNORE'))
          Find.prune
        end

        # check for package.xml in this directory
        manifest_path = File.join(path,'package.xml')
        if File.exist?(manifest_path)
          pkg_dir = path

          # compute the relative path from the root of the repo to this directory
          relpath = Pathname.new(File.join(*pkg_dir)).relative_path_from(Pathname.new(local_path))

          # read the package manifest
          package_xml = IO.read(manifest_path)
          package_doc = REXML::Document.new(package_xml)

          # extract package manifest info
          package_name = REXML::XPath.first(package_doc, "/package/name/text()").to_s.rstrip.lstrip

          puts " -- adding package " << package_name

          package_info = {
            'name' => package_name,
            'distro' => distro,
            'raw_uri' => File.join(data['raw_uri'], relpath),
            # required package info
            'name' => package_name,
            'version' => REXML::XPath.first(package_doc, "/package/version/text()").to_s,
            'license' => REXML::XPath.first(package_doc, "/package/license/text()").to_s,
            'description' => REXML::XPath.first(package_doc, "/package/description/text()").to_s,
            'maintainers' => REXML::XPath.each(package_doc, "/package/maintainer/text()").map { |m| m.to_s },
            # optional package info
            'authors' => REXML::XPath.each(package_doc, "/package/author/text()").map { |a| a.to_s },
            # rosindex metadata
            'tags' => REXML::XPath.each(package_doc, "/package/export/rosindex/tags/tag/text()").map { |t| t.to_s },
            # package contents
            'readme' => nil,
            'readme_rendered' => nil
          }

          # check for readme in same directory as package.xml
          package_info['readme_rendered'], package_info['readme'] = get_readme(
            site,
            pkg_dir,
            package_info['raw_uri'])

          packages[package_name] = package_info

          # stop searching a directory after finding a package.xml
          Find.prune
        end
      end
    end

    return packages
  end

  # scrape a version of a repository for packages and their contents
  def scrape_version(site, repo, distro, snapshot, vcs, version)

    unless repo.uri
      puts ("WARNING: no URI for "+repo.name+" "+repo.id+" "+distro).yellow
      return
    end

    # check out this branch
    vcs.checkout(version)

    # initialize this snapshot data
    data = snapshot.data = {
      # get the uri for resolving raw links (for imgages, etc)
      'raw_uri' => get_raw_uri(repo.uri, snapshot.version),
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
        puts " --- Setting repo instance " << repo.id << "as default for package " << package_name << " in distro " << distro
        @package_names[package_name].repos[distro] = repo
        @package_names[package_name].snapshots[distro] =  package
      end
    end
  end

  def scrape_repo(site, repo)

    # open or initialize this repo
    local_path = File.join(site.config['checkout_path'], repo.name, repo.id)

    # get the repo
    vcs = get_vcs(local_path, repo.uri, repo.type)
    unless vcs.valid? then return end

    # get versions suitable for checkout for each distro
    repo.snapshots.each do |distro, snapshot|

      # get explicit version (this is either set or nil)
      explicit_version = snapshot.version

      if explicit_version
        puts " -- looking for version " << explicit_version << " for distro " << distro
      else
        puts " -- no explicit version for distro " << distro << " looking for implicit version "
      end

      # get the version
      version, snapshot.version = vcs.get_version(distro, explicit_version)

      # scrape the data (packages etc)
      if version
        puts (" --- scraping version for " << repo.name << " instance: " << repo.id << " distro: " << distro).blue
        scrape_version(site, repo, distro, snapshot, vcs, version)
      else
        puts (" --- no version for " << repo.name << " instance: " << repo.id << " distro: " << distro).yellow
      end
    end

  end

  def generate(site)

    # create the checkout path if necessary
    checkout_path = site.config['checkout_path']
    puts "checkout path: " + checkout_path
    unless File.exist?(checkout_path)
      FileUtils.mkpath(checkout_path)
    end

    # construct list of known ros distros
    $all_distros = site.config['distros'] + site.config['old_distros']

    # the global index of repos
    @all_repos = Hash.new
    # the list of repo instances by name
    @repo_names = Hash.new {|h,k| h[k]=RepoInstances.new(k)}
    # the list of package instances by name
    @package_names = Hash.new {|h,k| h[k]=PackageInstances.new(k)}

    #blank_distro_map = Hash[$all_distros.collect { |d| [d, {}] }]

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
          puts repo_data.inspect


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
            puts ("ERROR: No source or doc information for repo: " + repo_name + " in rosidstro file: " + rosdistro_filename).red
            next
          else
            puts ("ERROR: No source, doc, or release information for repo: " + repo_name+ " in rosidstro file: " + rosdistro_filename).red
            next
          end

          # create a new repo structure for this remote
          repo = Repo.new(get_id(source_uri), repo_name, source_type, source_uri, 'Official in '+distro)
          if @all_repos.key?(repo.id)
            repo = @all_repos[repo.id]
          else
            puts " -- Adding repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s
            # store this repo in the unique index
            @all_repos[repo.id] = repo
          end

          # add the specific version from this instance
          repo.snapshots[distro].version = source_version
          repo.snapshots[distro].released = repo_data.key?('release')

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
              puts ("ERROR: fools trying to use bazaar: " + rosinstall_filename).red
              next
            end

            #puts repo_type.inspect
            #puts repo_data.inspect

            repo_name = repo_data['local-name'].to_s
            repo_uri = repo_data['uri'].to_s
            repo_version = repo_data['version'].to_s

            # create a new repo structure for this remote
            repo = Repo.new(get_id(repo_uri), repo_name, repo_type, repo_uri, 'Official in '+distro)
            if @all_repos.key?(repo.id)
              repo = @all_repos[repo.id]
            else
              puts " -- Adding repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s
              # store this repo in the unique index
              @all_repos[repo.id] = repo
            end

            # add the specific version from this instance
            repo.snapshots[distro].version = repo_version
            repo.snapshots[distro].released = repo_data.key?('release')

            # store this repo in the name index
            @repo_names[repo.name].instances[repo.id] = repo
            unless @repo_names.key?(repo.name)
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
        repo = Repo.new(get_id(instance['uri']), repo_name, instance['type'], instance['uri'], instance['purpose'])

        puts " -- Added repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s

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
        if instance['default'] or @repo_names[repo.name].default == nil
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
    n_repo_list_pages = @repo_names.length / repos_per_page

    repos_alpha = @repo_names.sort_by { |name, instances| name }

    (0..n_repo_list_pages).each do |page_index|

      p_start = page_index * repos_per_page
      p_end = [@repo_names.length, p_start+repos_per_page].min
      list_alpha = repos_alpha.slice(p_start, repos_per_page)

      site.pages << RepoListPage.new(
        site,
        n_repo_list_pages + 1,
        page_index + 1,
        list_alpha)

      if page_index == 0
        site.pages << RepoListPage.new(
          site,
          n_repo_list_pages + 1,
          page_index + 1,
          list_alpha,
          true)
      end
    end

    # create package list pages
    packages_per_page = site.config['packages_per_page']
    n_package_list_pages = @package_names.length / packages_per_page

    packages_alpha = @package_names.sort_by { |name, instances| name }

    (0..n_package_list_pages).each do |page_index|

      p_start = page_index * packages_per_page
      p_end = [@package_names.length, p_start+packages_per_page].min
      list_alpha = packages_alpha.slice(p_start, packages_per_page)

      site.pages << PackageListPage.new(
        site,
        n_package_list_pages + 1,
        page_index + 1,
        list_alpha)

      if page_index == 0
        site.pages << PackageListPage.new(
          site,
          n_package_list_pages + 1,
          page_index + 1,
          list_alpha,
          true)
      end
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
  def initialize(site, n_list_pages, page_index, list_alpha, default=false)
    @site = site
    @base = site.source
    @dir = unless default then 'packages/page/'+page_index.to_s else 'packages' end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'packages.html')
    self.data['pager'] = {
      'base' => 'packages'
    }
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
  def initialize(site, n_list_pages, page_index, list_alpha, default=false)
    @site = site
    @base = site.source
    @dir = unless default then 'repos/page/'+page_index.to_s else 'repos' end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repos.html')
    self.data['pager'] = {
      'base' => 'repos'
    }
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

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, instance.snapshots)
    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class SearchIndexFile < Jekyll::StaticFile
  # Override write as the search.json index file has already been created
  def write(dest)
    true
  end
end

