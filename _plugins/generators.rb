
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

$fetched_uris = {}

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

def get_readme(site, readme_path, raw_uri)
  if File.exist?(readme_path)
    # read in the readme and fix links
    readme = IO.read(readme_path)
    readme_html = render_md(site, readme)
    readme_html = '<div class="rendered-markdown">'+readme_html+"</div>"
    readme_rendered, _ = fix_image_links(readme_html, raw_uri)
  else
    readme = nil
    readme_rendered = nil
  end

  return readme_rendered, readme
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

# Computes a github uri from a github ns and repo
def github_uri(ns,repo)
  return 'https://github.com/%s/%s.git' % [ns,repo]
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

# Creates a unique instance name based on the host server
def make_instance_name(instance)
  return [instance['type'], instance['ns'], instance['name']].join("/")
end

class PackageSnapshot < Liquid::Drop
  # This represents a snapshot of a ROS package found in a repo snapshot
  attr_accessor :name, :repo, :snapshot, :version, :data
  def initialize(name, repo, snapshot, data)
    @name = name
    @repo = repo
    @snapshot = snapshot
    @version = snapshot.version
    @data = data
  end
end

class RepoSnapshot < Liquid::Drop
  # This represents a snapshot of a version control repository
  attr_accessor :released, :distro, :version, :data, :packages
  def initialize(version, distro, released)
    @version = version
    @released = released
    @distro = distro
    @data = {}
    @packages = {}
  end
end

class Repo < Liquid::Drop
  # This represents a remote repository
  attr_accessor :name, :id, :uri, :purpose, :versions, :tags
  def initialize(name, type, uri, purpose)
    @name = name
    # generate unique id
    p_uri = URI(uri)
    @id = (p_uri.host.split('.').reject{|v| if v.length < 3 or v == 'com' or v == 'org' or v == 'edu' then v end} + p_uri.path.split(%r{[./]}).reject{|v| if v.length == 0 then true end}[0,2]).join('-')
    @uri = uri
    @type = type
    @purpose = purpose
    @versions = Hash[$all_distros.collect { |d| [d, RepoSnapshot.new(nil, d, false)] }]
    @tags = []
  end
end

class RepoInstances < Liquid::Drop
  # This represents a group of repositories with the same name
  attr_accessor :name, :default, :instances
  def initialize(name)
    @name = name
    @default = nil
    @instances = {}
  end
end

class PackageInstances < Liquid::Drop
  # This represents a group of package snapshots with the same name
  attr_accessor :name, :tags, :instances, :versions
  def initialize(name)
    @name = name
    @tags = []
    @versions = Hash[$all_distros.collect { |d| [d, nil] }]
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

    puts "Getting remotes for for "+repo_instances.name

    # open or initialize this repo
    local_path = File.join(site.config['checkout_path'], repo_instances.name)
    #g = if File.exist?(local_path) then Git.open(local_path) else Git.init(local_path) end
    g = if File.exist?(local_path) then Rugged::Repository.new(local_path) else Rugged::Repository.init_at(local_path) end

    # add / fetch all the instances
    repo_instances.instances.each do |id, repo|

      uri = repo.uri
      repo.versions.each do |distro, version|

        # make sure there's an actual uri
        unless uri
          #puts ("WARNING: No URI: " + details.inspect).yellow
          next
        end

        # make sure the uri actually exists before adding it
        resp = Typhoeus.get(uri, followlocation: true, nosignal: true)
        if resp.code == 404
          puts ("ERROR: "+resp.code.to_s+" Bad URI: " + uri).red
          next
        end

        # find the remote if it already exists under a different name
        new_remote = true
        remote = nil
        g.remotes.each do |r|
          #puts "remote url: " << r.url
          if r.url == uri
            remote = r
            new_remote = false
            break
          end
        end

        # add the remote if it isn't found
        # note that a single authority can have multiple uris
        if new_remote
          puts " - adding remote "+id+" from: " + uri.to_s
          remote = g.remotes.create(id, uri)
        end

        unless remote
          puts ("ERROR: failed to add remote").red
          next
        end

        # fetch the remote
        unless $fetched_uris.key?(uri)
          if true or new_remote or (File.mtime(File.join(local_path,'.git')) < (Time.now() - (60*60*24)))
            puts " - fetching remote "+repo.name+": "+id+" from: " + remote.url
            g.fetch(remote)
          else
            puts " - not fetching remote "+repo.name+": "+id
          end
          $fetched_uris[uri] = true
        end
      end
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
            File.join(pkg_dir,'README.md'),
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
  def scrape_version(site, repo, distro, snapshot, local_path, g, version)

    # extract info (including packages) from each version of this repo
    uri = repo.uri

    unless uri
      puts ("WARNING: no URI for "+repo.name+" "+repo.id+" "+distro).yellow
      return
    end
    puts " - uri: " << uri

    # get the version shortname if it's a branch
    version_name = version.to_s.split('/')[-1]

    # check out this branch
    puts " - checking out " << version.name+" from " << repo.uri << " for instance: " << repo.id << " distro: " << distro
    begin
      g.checkout(version)
    rescue
      g.reset(version.name, :hard)
    end

    # initialize this snapshot data
    data = snapshot.data = {
      # get the uri for resolving raw links (for imgages, etc)
      'raw_uri' => get_raw_uri(uri, version_name),
      # get the date of the last modification
      'last_commit_time' => g.last_commit.time.to_s,
      'readme' => nil,
      'readme_rendered' => nil}

    # load the repo readme for this branch if it exists
    data['readme_rendered'], data['readme'] = get_readme(
      site,
      File.join(local_path,'README.md'),
      data['raw_uri'])

    # get all packages from the repo
    packages = find_packages(site, distro, snapshot.data, local_path)

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
        @package_names[package_name].versions[distro] = package
      end
    end
  end

  def scrape_repo(site, repo)

    # open or initialize this repo
    local_path = File.join(site.config['checkout_path'], repo.name)
    #g = if File.exist?(local_path) then Git.open(local_path) else Git.init(local_path) end
    g = if File.exist?(local_path) then Rugged::Repository.new(local_path) else Rugged::Repository.init_at(local_path) end

    # get versions suitable for checkout for each distro
    repo.versions.each do |distro, snapshot|

      # get explicit version (this is either set or nil)
      explicit_version = snapshot.version

      if explicit_version
        puts " - looking for version " << explicit_version << " for distro " << distro
      else
        puts " - no explicit version for distro " << distro
      end

      # get the version
      version = nil

      # get the version if it's a branch
      g.branches.each() do |branch|
        # get the branch shortname
        branch_name = branch.name.split('/')[-1]

        # detached branches are those checked out by the system but not given names
        if branch.to_s.include? 'detached' then next end
        if branch.remote_name != repo.id then next end

        #puts " -- examining branch " << branch.name << " trunc: " << branch_name << " from remote: " << branch.remote_name
        #puts " - should have " << distro << " version " << explicit_version.to_s

        # save the branch as the version if it matches either the explicit
        # version or the distro name
        if explicit_version
          if branch_name == explicit_version
            version = branch
            break
          end
        elsif branch_name.include? distro
          snapshot.version = branch_name
          version = branch
          break
        end
      end

      # get the version if it's a tag
      g.tags.each do |tag|
        tag_name = tag.to_s

        # save the tag if it matches either the explicit version or the distro name
        if explicit_version
          if tag_name == explicit_version
            version = tag
            break
          end
        elsif tag_name.include? distro
          snapshot.version = tag_name
          version = tag
          break
        end
      end

      # scrape the data (packages etc)
      if version
        puts (" --- scraping version for " << repo.name << " instance: " << repo.id << " distro: " << distro).blue
        scrape_version(site, repo, distro, snapshot, local_path, g, version)
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
      unless File.exist?(rosdistro_filename) then next end
      distro_data = YAML.load_file(rosdistro_filename)

      distro_data['repositories'].each do |repo_name, repo_data|

        # limit repos if requested
        if not @repo_names.has_key?(repo_name) and site.config['max_repos'] > 0 and @repo_names.length > site.config['max_repos'] then next end

        puts " - "+repo_name

        # TODO: get the release repo to get the upstream repo

        source_uri = nil
        source_version = nil

        # only index if it has a source repo
        if repo_data.has_key?('source')
          if repo_data['source']['type'] == 'git'
            source_uri = repo_data['source']['url'].to_s
            source_version = repo_data['source']['version'].to_s
          else
            puts (" -- Can't handle repo type: " + repo_data['source']['type']).red
            next
          end
        else
          # TODO: get source repo from release repo here
          next
        end

        # create a new repo structure for this remote
        repo = Repo.new(repo_name, "git", source_uri, 'Official in '+distro)
        if @all_repos.key?(repo.id)
          repo = @all_repos[repo.id]
        else
          puts " -- Adding repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s
          # store this repo in the unique index
          @all_repos[repo.id] = repo
        end

        # add the specific version from this instance
        repo.versions[distro].version = source_version
        repo.versions[distro].released = repo_data.key?('release')

        # store this repo in the name index
        @repo_names[repo.name].default = repo
        @repo_names[repo.name].instances[repo.id] = repo

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
        repo = Repo.new(repo_name, "git", instance['uri'], instance['purpose'])

        puts " -- Added repo for " << repo.name << " instance: " << repo.id << " from uri " << repo.uri.to_s

        # add distro versions for instance
        $all_distros.each do |distro|

          # get the explicit version identifier for this distro
          explicit_version = if instance['distros'].key?(distro) and instance['distros'][distro].key?('version') then instance['distros'][distro]['version'] else nil end

          # add the specific version from this instance
          repo.versions[distro].version = explicit_version
          repo.versions[distro].released = false
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
        repo.versions.each do |distro, repo_snapshot|

          if repo_snapshot.version == nil then next end

          repo_snapshot.packages.each do |package_name, package|

            if package.nil? then next end

            p = package.data

            readme_filtered = if p['readme'] then self.strip_stopwords(p['readme']) else "" end

            index << {
              'id' => index.length,
              'baseurl' => site.config['baseurl'],
              'url' => File.join('/p',package_name,instance_id)+"#"+distro,
              'last_updated' => nil,
              'tags' => p['tags'] * " ",
              'name' => package_name,
              'version' => p['version'],
              'description' => p['description'],
              'maintainers' => p['maintainers'] * " ",
              'authors' => p['authors'] * " ",
              'distro' => distro,
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

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, repo.versions)

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

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, package_instances.versions)

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

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, instance.versions)
    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class SearchIndexFile < Jekyll::StaticFile
  # Override write as the search.json index file has already been created
  def write(dest)
    true
  end
end

