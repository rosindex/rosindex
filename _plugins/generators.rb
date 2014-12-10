
# NOTE: This whole file is one big hack. Don't judge.

require 'git'
require 'fileutils'
require 'find'
require 'rexml/document'
require 'rexml/xpath'
require 'pathname'
require 'json'
require 'uri'
require 'yaml'
require "net/http"

require 'nokogiri'
require 'colorize'
require 'typhoeus'

# Modifies markdown image links so that they link to github user content
def fix_image_links(text, raw_uri, additional_path = '')
  readme_doc = Nokogiri::HTML(text)
  readme_doc.xpath("//img[@src]").each() do |el|
    puts 'img: '+el['src'].to_s
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
    readme = "*No README.md file found. Maybe try [wiki.ros.org](http://www.ros.org/browse/list.php)*"
    readme_rendered = render_md(site, readme)
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

  def generate(site)

    # create the checkout path if necessary
    checkout_path = site.config['checkout_path']
    puts "checkout path: " + checkout_path
    unless File.exist?(checkout_path)
      FileUtils.mkpath(checkout_path)
    end

    # construct list of known ros distros
    all_distros = site.config['distros'] + site.config['old_distros']

    # the global index of repos
    all_repos = Hash.new {|h,k| h[k]={}}
    # the global index of packages
    all_packages = Hash.new {|h,k| h[k]={}}

    # get the repositories from the rosdistro files
    all_distros.each do |distro|

      puts "processing rosdistro: "+distro

      # read in the rosdistro distribution file
      rosdistro_filename = File.join(site.config['rosdistro_path'],distro,'distribution.yaml')
      unless File.exist?(rosdistro_filename) then next end
      distro_data = YAML.load_file(rosdistro_filename)

      distro_data['repositories'].each do |repo_name, repo_data|

        # limit repos if requested
        if site.config['max_repos'] > 0 and all_repos.length > site.config['max_repos'] then break end

        puts " - "+repo_name

        # TODO: get the release repo to get the upstream repo

        source_uri = nil
        source_version = nil

        # only index if it has a source repo
        if repo_data.has_key?('source')
          if repo_data['source']['type'] == 'git'
            source_uri = repo_data['source']['url']
            source_version = repo_data['source']['version']
          end
        else
          next
        end

        # store the variant for the repo from this distro
        repo = all_repos[repo_name] = {
          'name' => repo_name,
          'tags' => [],
          'default' => 'rosdistro',
          'instances' => {}
        }
        repo['instances']['rosdistro'] = {
          'name' => 'rosdistro',
          'repo' => repo,
          'uri' => source_uri,
          'released' => repo_data.has_key?('release'),
          'distro_branches' => { distro => source_version },
          'distro_versions' => {},
          'distros' => {}
        }
      end
    end

    # add additional repo instances to the main dict
    Dir.glob(File.join(site.config['repos_path'],'*.yaml')) do |repo_filename|

      # limit repos if requested
      if site.config['max_repos'] > 0 and all_repos.length > site.config['max_repos'] then break end

      # read in the repo data
      repo_name = File.basename(repo_filename, File.extname(repo_filename))
      repo_data = YAML.load_file(repo_filename)

      # initialize this repo in the repo index if it doesn't exist yet
      unless all_repos.has_key?(repo_name)
        all_repos[repo_name] = {
          'name' => repo_name,
          'tags' => [],
          'default' => nil,
          'instances' => {}
        }
      end

      # get the repo struct for this repo and update it
      repo = all_repos[repo_name]
      repo['tags'] = repo_data['tags'] or []
      repo['default'] = repo['default'] or repo_data['default']

      # add all the instances
      repo_data['instances'].each do |instance_name, instance|

        # skip instances missing uri
        unless instance['uri'] then next end

        # add this remote to the repo instances dict
        repo['instances'][instance_name] = {
          'name' => instance_name,
          'repo' => repo,
          'uri' => instance['uri'],
          'released' => false,
          'distro_branches' => (repo_file.data['distros'] or {}),
          'distro_versions' => {},
          'distros' => {}
        }
      end
    end

    puts "Found " << all_repos.length.to_s << " repos."

    # clone / fetch all the repos
    all_repos.each do |repo_name, repo|
      puts "Getting remotes for for "+repo_name

      # open or initialize this repo
      local_path = File.join(checkout_path, repo_name)
      g = if File.exist?(local_path) then Git.open(local_path) else Git.init(local_path) end

      # add / fetch all the instances
      repo['instances'].each do |instance_name, instance|

        unless instance['uri']
          puts ("WARNING: No URI: " + instance.inspect).yellow
          next
        end

        # make sure the uri actually exists
        resp = Typhoeus.get(instance['uri'], followlocation: true)

        if resp.code == 404
          puts ("ERROR: "+resp.code.to_s+" Bad URI: " + instance.inspect).red
          next
        end

        # find the remote if it already exists
        new_remote = true
        remote = nil
        g.remotes.each do |r|
          if r.url == instance['uri']
            remote = r
            new_remote = false
          end
        end

        unless remote then next end

        # add the remote if it isn't found
        if new_remote
          puts " - adding remote "+instance_name+" from: " + instance['uri'].to_s
          remote = g.add_remote(instance_name, instance['uri'])
        end

        # fetch the remote
        if new_remote or File.mtime(local_path) < (Time.now() - (60*60*24))
          puts " - fetching remote "+instance_name+" from: " + remote.url
          g.fetch(remote)
        else
          puts " - not fetching remote "+instance_name+" since it is less than a day old"
        end

        # get versions suitable for checkout for each distro
        all_distros.each do |distro|
          # get explicit version
          explicit_version = instance['distro_branches'][distro]

          # get the version if it's a branch
          g.branches.each do |branch|
            # detached branches are those checked out by the system but not given names
            if branch.to_s.include? 'detached' then next end

            # get the branch instance name and shortname
            remote_name = branch.to_s.split('/')[1]
            branch_name = branch.to_s.split('/')[-1]

            # save the branch as the version if it matches either the explicit version or the distro name
            if remote_name == instance_name
              if explicit_version
                if branch_name == explicit_version
                  instance['distro_versions'][distro] = branch
                  break
                end
              elsif branch_name.include? distro
                instance['distro_versions'][distro] = branch
                break
              end
            end
          end

          unless instance['distro_versions'][distro] then next end

          # get the version if it's a tag
          g.tags.each do |tag|
            tag_name = tag.to_s

            # save the tag if it matches either the explicit version or the distro name
            if explicit_version
              if tag_name == explicit_version
                instance['distro_versions'][distro] = tag
                break
              end
            elsif tag_name.include? distro
              instance['distro_versions'][distro] = tag
              break
            end
          end
        end

        # debug which versions were found
        puts instance['distro_versions'].inspect

        # extract info (including packages) from each version of this repo
        instance['distro_versions'].each do |distro, version|
          uri  = instance['uri']

          # get the version shortname if it's a branch
          version_name = version.to_s.split('/')[-1]

          # initialize this instance struct
          branch_info = instance['distros'][distro] = {
            'raw_uri' => get_raw_uri(instance['uri'], version_name),
            'packages' => {},
            'readme' => nil,
            'readme_rendered' => nil}

          # check out this branch
          puts " - checking out "+version.to_s+" from "+instance['uri']
          g.reset_hard(version)
          #g.checkout(version)

          # load the repo readme for this branch if it exists
          branch_info['readme_rendered'], branch_info['readme'] = get_readme(
            site,
            File.join(local_path,'README.md'),
            branch_info['raw_uri'])

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
                package_name = REXML::XPath.first(package_doc, "/package/name/text()").to_s


                puts " -- adding package " << package_name

                package_info = {
                  'name' => package_name,
                  'repo' => all_repos[repo_name],
                  'distro' => distro,
                  'raw_uri' => File.join(branch_info['raw_uri'], relpath),
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

                # add package tags to the containing repo
                package_info['tags'].each do |tag|
                  unless instance['tags'].include? tag then instance['tags'] << tag end
                end

                # check for readme in same directory as package.xml
                package_info['readme_rendered'], package_info['readme'] = get_readme(
                  site,
                  File.join(pkg_dir,'README.md'),
                  package_info['raw_uri'])

                # add this package to the global package dict
                unless all_packages[package_name].has_key?('instances')
                  puts " -- adding new package" << package_name
                  all_packages[package_name] = {
                    'name' => package_name,
                    'instances' => {}}
                end
                unless all_packages[package_name]['instances'].has_key?(instance_name)
                  puts " -- adding new package " << package_name << " instance " << instance_name
                  all_packages[package_name]['instances'][instance_name] = {
                    'name' => package_name,
                    'repo' => all_repos[repo_name],
                    'distros' => {}
                  }
                end

                # reference the package info in the global indices
                all_packages[package_name]['instances'][instance_name]['distros'][distro] = package_info
                all_repos      [repo_name]['instances'][instance_name]['distros'][distro]['packages'][package_name] = package_info

                # stop searching a directory after finding a package.xml
                Find.prune
              end
            end
          end
        end
      end

      # create the repo pages
      puts " - creating pages for repo "+repo['name']+"..."

      # create a page that lists all the repo instances
      site.pages << RepoPage.new(site, repo)

      # create pages for each repo instance
      repo['instances'].each do |instance_name, instance|

        site.pages << RepoInstancePage.new(site, repo, instance_name)

        if repo['default'] == instance_name
          site.pages << RepoInstancePage.new(site, repo, instance_name, true)
        end
      end
    end

    # create package pages
    puts "Found "+String(all_packages.length)+" packages total."

    all_packages.each do |package_name, package|

      # create package page which lists all the instances
      site.pages << PackagePage.new(site, package)

      # create a page for each instance
      package['instances'].each do |instance_name, package_instance|

        repo = package_instance['repo']

        instances = all_repos[repo['name']]

        site.pages << PackageInstancePage.new(
          site,
          repo,
          package,
          instance_name)

        if repo['default'] == instance_name
          site.pages << PackageInstancePage.new(
            site,
            repo,
            package,
            instance_name,
            true)
        end
      end
    end
    
    # create repo list pages
    repos_per_page = site.config['repos_per_page']
    n_repo_list_pages = all_repos.length / repos_per_page

    repos_alpha = all_repos.sort_by { |name, details| name }

    (0..n_repo_list_pages).each do |page_index|

      p_start = page_index * repos_per_page
      p_end = [all_repos.length, p_start+repos_per_page].min
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
    n_package_list_pages = all_packages.length / packages_per_page

    packages_alpha = all_packages.sort_by { |name, details| name }

    (0..n_package_list_pages).each do |page_index|

      p_start = page_index * packages_per_page
      p_end = [all_packages.length, p_start+packages_per_page].min
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
    all_packages.each do |package_name, package|
      package['instances'].each do |instance_name, instance|
        instance['distros'].each do |distro, p|

          if package.nil? then next end

          readme_filtered = self.strip_stopwords(p['readme'])

          index << {
            'baseurl' => site.config['baseurl'],
            'url' => File.join('/p',package_name,instance_name)+"#"+distro,
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

          puts 'indexed: ' << "#{package_name} #{instance_name} #{distro}"
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

class RepoPage < Jekyll::Page
  def initialize(site, repo)
    @site = site
    @base = site.source
    @dir = File.join('repos', repo['name'])
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repo.html')
    self.data['repo'] = repo
    self.data['instances'] = repo['instances']
  end
end

def get_available_distros(site, instance)
  # create easy-to-process lists of available distros for the switcher

  available_distros = {}
  available_older_distros = {}

  site.config['distros'].each do |distro|
    available_distros[distro] = instance['distros'].has_key?(distro)
  end

  site.config['old_distros'].each do |distro|
    if instance['distros'].has_key?(distro)
      available_older_distros[distro] = true
    end
  end

  return available_distros, available_older_distros, available_older_distros.length
end


class RepoInstancePage < Jekyll::Page
  def initialize(site, repo, instance_name, default = false)

    instance_base = File.join('r', repo['name'])

    @site = site
    @base = site.source
    @dir = if default then instance_base else File.join(instance_base, instance_name) end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'repo_instance.html')
    # clone (or update) git repo
    # for each ROSDISTRO-devel branch
    # list all ROS packages in the repo
    #site.pages << PackagePage.new(...)
    self.data['repo'] =   repo
    self.data['instances'] = repo['instances']
    self.data['instance'] = repo['instances'][instance_name]
    self.data['instance_base'] = instance_base

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, repo['instances'][instance_name])

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
  end
end

class PackagePage < Jekyll::Page
  def initialize(site, package)
    @site = site
    @base = site.source
    @dir = File.join('packages',package['name'])
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package.html')
    self.data['package_name'] = package['name']
    self.data['package_instances'] = package['instances']
  end
end

class PackageInstancePage < Jekyll::Page
  def initialize(site, repo, package, instance_name, default=false)

    instance_base = File.join('p', package['name'])

    @site = site
    @base = site.source
    @dir = if default then instance_base else File.join(instance_base, instance_name) end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package_instance.html')

    # clone (or update) git repo
    # for each ROSDISTRO-devel branch
    # list all ROS packages in the repo
    #site.pages << PackagePage.new(...)
    self.data['repo'] = repo
    self.data['instances'] = repo['instances']
    self.data['instance'] = repo['instances'][instance_name]
    self.data['instance_base'] = instance_base
    self.data['package_instances'] = package['instances']
    self.data['package_instance'] = package['instances'][instance_name]

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, repo['instances'][instance_name])

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class SearchIndexFile < Jekyll::StaticFile
  # Override write as the search.json index file has already been created
  def write(dest)
    true
  end
end

