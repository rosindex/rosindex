
# http://www.rubydoc.info/github/mojombo/jekyll/Jekyll
#
require 'git'
require 'fileutils'
require 'find'
require 'rexml/document'
require 'rexml/xpath'
require 'nokogiri'         

def render_md(site, readme)
  mkconverter = site.getConverterImpl(Jekyll::Converters::Markdown)
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
      instances = Hash.new {|h,k| h[k]=[]}

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
          if instance.has_key?('distro_branches') and instance['distro_branches'].has_key?(distro) and instance['distro_branches'][distro] == branch_name
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
              readme_doc = Nokogiri::HTML(readme_html)
              readme_doc.xpath("//img[@src]").each() do |el|
                print('img: '+el['src'].to_s)
                unless el['src'].start_with?('http')
                  el['src'] = ('https://raw.githubusercontent.com/%s/%s/%s/' % [instance['ns'], instance['name'], branch_name])+el['src']
                end
              end

              branch_info['readme_rendered'] = readme_doc.to_s
            else
              branch_info['readme_rendered'] = render_md(
                site,
                "*No README.md file found. Maybe try [wiki.ros.org](http://www.ros.org/browse/list.php)*")
            end

            # find packages in this branch
            Find.find(local_path) do |path|
              if FileTest.directory?(path)
                if File.basename(path)[0] == ?.
                  Find.prune
                else
                  next
                end
              else
                tail = path.split(File::SEPARATOR)[-1]
                #print("::"+path+": "+tail+"\n")
                if tail == 'package.xml'
                  # extract package manifest info
                  package_xml = IO.read(path)
                  package_doc = REXML::Document.new(package_xml)
                  package_info = {
                    'name' => REXML::XPath.first(package_doc, "/package/name/text()").to_s,
                    'version' => REXML::XPath.first(package_doc, "/package/version/text()").to_s,
                    'license' => REXML::XPath.first(package_doc, "/package/license/text()").to_s,
                    'description' => REXML::XPath.first(package_doc, "/package/description/text()").to_s
                  }
                  #print(package_info.to_s+"\n\n")

                  branch_info['packages'][package_info['name']] = package_info
                end
              end
            end

            # store this branch info
            instances[instance_name]['distros'][distro] = branch_info
          end
        end
      end

      # create the actual pages
      print("creating pages...\n")

      site.pages << RepoPage.new(
        site,
        site.source,
        File.join('r', repo.data['name']),
        repo,
        instances)

      instances.each do |instance_name, instance|

        site.pages << RepoInstancePage.new(
          site,
          site.source,
          File.join('r', repo.data['name'], instance_name),
          repo,
          instances,
          instance)


        #all_distros.each do |distro|
          #site.pages << RepoInstanceDistroPage.new(
            #site,
            #site.source,
            #File.join('r', repo.data['name'], instance_name, distro),
            #repo,
            #if instance['distros'].has_key?(distro) then instance['distros'][distro] else nil end)
        #end
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

class RepoInstancePage < Jekyll::Page
  def initialize(site, base, dir, repo, instances, instance)
    @site = site
    @base = base
    @dir = dir
    @name = 'index.html'

    self.process(@name)
    self.read_yaml(File.join(base, '_layouts'),'repo_instance.html')
    # clone (or update) git repo
    # for each ROSDISTRO-devel branch
    # list all ROS packages in the repo
    #site.pages << PackagePage.new(...)
    self.data['repo'] =   repo
    self.data['instances'] = instances
    self.data['instance'] = instance

    # create easy-to-process lists of available distros for the switcher
    self.data['available_distros'] = {}
    self.data['available_older_distros'] = {}

    site.config['distros'].each do |distro|
      self.data['available_distros'][distro] = instance['distros'].has_key?(distro)
    end
    site.config['old_distros'].each do |distro|
      if instance['distros'].has_key?(distro)
        self.data['available_older_distros'][distro] = true
      end
    end
    self.data['n_available_older_distros'] = self.data['available_older_distros'].length

    print('old distros: '+self.data['available_older_distros'].inspect+"\n")

    self.data['all_distros'] = site.config['distros'] + site.config['old_distros']
  end
end

class PackagePage < Jekyll::Page
  def initialize(site, base, dir, name)
    super(site, base, dir, name)
  end
end

