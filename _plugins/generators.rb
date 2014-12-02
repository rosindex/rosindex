
# NOTE: This whole file is one big hack. Don't judge.

require 'git'
require 'fileutils'
require 'find'
require 'rexml/document'
require 'rexml/xpath'
require 'nokogiri'
require 'pathname'

def fix_image_links(text, ns, name, branch, additional_path = '')
  readme_doc = Nokogiri::HTML(text)
  readme_doc.xpath("//img[@src]").each() do |el|
    print('img: '+el['src'].to_s+"\n")
    unless el['src'].start_with?('http')
      el['src'] = ('https://raw.githubusercontent.com/%s/%s/%s/%s/' % [ns, name, branch, additional_path])+el['src']
    end
  end

  return readme_doc.to_s, readme_doc
end

def render_md(site, readme)
  mkconverter = site.getConverterImpl(Jekyll::Converters::Markdown)
  readme.gsub! "```","\n```"
  readme.gsub! '```shell','```bash'
  return mkconverter.convert(readme)
end

def github_uri(ns,repo)
  return 'https://github.com/%s/%s.git' % [ns,repo]
end

def make_instance_name(instance)
  return [instance['type'], instance['ns'], instance['name']].join("/")
end

class GitScraper < Jekyll::Generator
  def generate(site)
    #print("site: "+site.inspect+"\n")
    print("cwd: " + Dir.getwd + "\n")
    checkout_path = site.config['checkout_path']
    print("checkout path: " + checkout_path + "\n")
    unless File.exist?(checkout_path)
      FileUtils.mkpath(checkout_path)
    end

    all_distros = site.config['distros'] + site.config['old_distros']

    # get the collection of repos
    repos = site.collections['repos']

    repo_instances = {}
    all_packages = Hash.new {|h,k| h[k]={}}

    # update and extract data from each repo
    repos.docs.each do |repo|
      # create or open the repo
      g = nil
      local_path = File.join(checkout_path, repo.data['name'])
      unless File.exist?(local_path)
        # initialize a new local repo
        print("initializing local repo: " + repo.data['name']+"\n")
        g = Git.init(local_path)
      else
        print("opening existing local repo: " + repo.data['name']+"\n")
        # open existing local repo
        g = Git.open(local_path)
      end

      # get branches corresponding to ros distros
      instances = Hash.new {|h,k| h[k]={}}

      # fetch all the instances
      repo.data['instances'].each do |instance_name, instance|
        # create page for this repo
        # TODO: deal with non-github types
        uri = github_uri(instance['ns'], instance['name'])

        # find the remote if it already exists
        remote = nil
        g.remotes.each do |r|
          if r.url == uri
            remote = r
          end
        end

        # add the remote if it isn't found
        if remote.nil?
          print(" - adding remote "+instance_name+" from: " + uri + "\n")
          remote = g.add_remote(instance_name, uri)
        end

        # fetch the remote
        print(" - fetching remote "+instance_name+" from: " + remote.url + "\n")
        g.fetch(remote)

        # add this remote to the repo instances dict
        instances[instance_name] = {
          'repo' => repo,
          'name' => instance_name,
          'uri' => uri,
          'distros' => {}
        }

      end

      # extract info from all branches
      g.branches.each do |branch|

        # detached branches are those checked out by the system but not given names
        if branch.to_s.include? 'detached'
          next
        end

        instance_name = branch.to_s.split('/')[1]
        branch_name = branch.to_s.split('/')[-1]

        instance = repo.data['instances'][instance_name]
        #print('branch: '+branch.to_s+' instance: '+instance.inspect)

        #print(' - remote name: '+instance_name+"\n")
        #print(' - short name: '+branch_name+"\n")

        # initialize branch info struct
        branch_info = {
          'name' => branch_name,
          'packages' => {}}

        # determine which instance to add it to
        all_distros.each do |distro|

          custom_branch = false
          if instance and instance.has_key?('distro_branches') and instance['distro_branches'].has_key?(distro) and instance['distro_branches'][distro] == branch_name
            print('custom branch for '+distro+': '+branch.to_s)
            custom_branch = true
          end

          if branch_name.include? distro or custom_branch

            # get README.md files from each distro (and forks)
            print(" - checking out "+branch.to_s+"\n")
            g.checkout(branch)
            readme_path = File.join(local_path,'README.md')

            # load the readme if it exists
            if File.exist?(readme_path)
              print(" - distro "+distro+" has readme\n")
              readme = IO.read(readme_path)
              readme_html = render_md(site, readme)
              readme_html = '<div class="rendered-markdown">'+readme_html+"</div>"

              # fix image links
              branch_info['readme_rendered'], _ = fix_image_links(readme_html, instance['ns'], instance['name'], branch_name)
            else
              branch_info['readme_rendered'] = render_md(
                site,
                "*No README.md file found. Maybe try [wiki.ros.org](http://www.ros.org/browse/list.php)*")
            end

            # find packages in this branch
            Find.find(local_path) do |path|
              if FileTest.directory?(path)
                if File.basename(path)[0] == ?. or File.exist?(File.join(path,'CATKIN_IGNORE'))
                  Find.prune
                else
                  next
                end
              else
                path_split = path.split(File::SEPARATOR)
                tail = path_split[-1]
                pkg_dir = path_split[0...-1]

                #print("::"+path+": "+tail+"\n")
                if tail == 'package.xml'
                  # extract package manifest info
                  package_xml = IO.read(path)
                  package_doc = REXML::Document.new(package_xml)
                  package_info = {
                    'name' => REXML::XPath.first(package_doc, "/package/name/text()").to_s,
                    'version' => REXML::XPath.first(package_doc, "/package/version/text()").to_s,
                    'license' => REXML::XPath.first(package_doc, "/package/license/text()").to_s,
                    'description' => REXML::XPath.first(package_doc, "/package/description/text()").to_s,
                    'maintainers' => REXML::XPath.each(package_doc, "/package/maintainer/text()").to_s,
                    'readme_rendered' => "no readme yet."
                  }
                  #print(package_info.to_s+"\n\n")

                  package_name = package_info['name']

                  # TODO: check for readme in same directory as package.xml
                  readme_path = File.join(pkg_dir,'README.md')
                  if File.exist?(readme_path)
                    print(' - found readme for '+package_name+"\n")
                    readme = IO.read(readme_path)
                    readme_html = render_md(site, readme)
                    readme_html = '<div class="rendered-markdown">'+readme_html+"</div>"

                    pn = Pathname.new(File.join(*pkg_dir))
                    ln = Pathname.new(local_path)
                    relpath = pn.relative_path_from(ln)
                    package_info['readme_rendered'], _ =
                      fix_image_links(readme_html, instance['ns'],
                                      instance['name'], branch_name,
                                      relpath.to_s)
                  else
                    #print(' - did not find readme for '+package_name+" at "+readme_path+"\n")
                  end

                  unless all_packages.has_key?(package_name)
                    all_packages[package_name] = {}
                  end

                  unless all_packages[package_name].has_key?(instance_name)
                    all_packages[package_name][instance_name] = {
                      'name' => package_name,
                      'repo' => repo,
                      'uri' => instances[instance_name]['uri'],
                      'distros' => {}
                    }
                  end

                  branch_info['packages'][package_name] = package_info
                  all_packages[package_name][instance_name]['distros'][distro] = package_info
                end
              end
            end

            # store this branch info
            instances[instance_name]['distros'][distro] = branch_info
          end
        end
      end

      # create the actual pages
      print("creating pages for this repo...\n")

      site.pages << RepoPage.new(
        site,
        site.source,
        File.join('repos', repo.data['name']),
        repo,
        instances)

      # create pages for each repo instance
      instances.each do |instance_name, instance|

        site.pages << RepoInstancePage.new(
          site,
          repo,
          instances,
          instance_name)

        if instance_name == repo.data['default']
          site.pages << RepoInstancePage.new(
            site,
            repo,
            instances,
            instance_name,
            true)
        end
      end

      repo_instances[repo.data['name']] = instances
    end

    # create package pages
    print("Found "+String(all_packages.length)+" packages total.\n")

    all_packages.each do |package_name, package_instances|

      # create package instance list page
      site.pages << PackagePage.new(
        site,
        package_name,
        package_instances)

      package_instances.each do |instance_name, package_instance|

        #print(package_instance.inspect+"\n\n")

        repo = package_instance['repo']

        #print('repo: '+repo.data.inspect+"\n")

        instances = repo_instances[repo.data['name']]

        site.pages << PackageInstancePage.new(
          site,
          repo,
          instances,
          package_instances,
          instance_name)

        if repo.data['default'] == instance_name
          site.pages << PackageInstancePage.new(
            site,
            repo,
            instances,
            package_instances,
            instance_name,
            true)
        end
      end
    end

    # create package list
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
        list_alpha
      )

      if page_index == 0
        site.pages << PackageListPage.new(
          site,
          n_package_list_pages + 1,
          page_index + 1,
          list_alpha,
          true
        )
      end
    end

  end
end

class RepoPage < Jekyll::Page
  def initialize(site, base, dir, repo, instances)
    @site = site
    @base = base
    @dir = dir
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(base, '_layouts'),'repo.html')
    self.data['repo'] = repo
    self.data['instances'] = instances
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
  def initialize(site, repo, instances, instance_name, default = false)

    instance_base = File.join('r', repo.data['name'])

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
    self.data['instances'] = instances
    self.data['instance'] = instances[instance_name]
    self.data['instance_base'] = instance_base

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, instances[instance_name])

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class PackageListPage < Jekyll::Page
  def initialize(site, n_package_list_pages, page_index, list_alpha, default=false)
    @site = site
    @base = site.source
    @dir = unless default then 'packages/page/'+page_index.to_s else 'packages' end
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'packages.html')
    self.data['n_package_list_pages'] = n_package_list_pages
    self.data['page_index'] = page_index
    self.data['list_alpha'] = list_alpha

    self.data['prev_page'] = [page_index - 1, 1].max
    self.data['next_page'] = [page_index + 1, n_package_list_pages].min

    self.data['near_pages'] = *([1,page_index-4].max..[page_index+4, n_package_list_pages].min)
  end
end

class PackagePage < Jekyll::Page
  def initialize(site, package_name, package_instances)
    @site = site
    @base = site.source
    @dir = File.join('packages',package_name)
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(@base, '_layouts'),'package.html')
    self.data['package_name'] = package_name
    self.data['package_instances'] = package_instances
  end
end

class PackageInstancePage < Jekyll::Page
  def initialize(site, repo, instances, package_instances, instance_name, default=false)

    instance_base = File.join('p', package_instances[instance_name]['name'])

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
    self.data['instances'] = instances
    self.data['instance'] = instances[instance_name]
    self.data['instance_base'] = instance_base
    self.data['package_instances'] = package_instances
    self.data['package_instance'] = package_instances[instance_name]

    self.data['available_distros'], self.data['available_older_distros'], self.data['n_available_older_distros'] = get_available_distros(site, instances[instance_name])

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

