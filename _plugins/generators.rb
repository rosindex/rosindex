
# http://www.rubydoc.info/github/mojombo/jekyll/Jekyll
#
require 'git'

def github_uri(ns,repo)
  return 'https://github.com/%s/%s.git' % [ns,repo]
end

def make_remote_name(type, ns, repo)
  return [type, ns, repo].join("/")
end

class GitScraper < Jekyll::Generator
  def generate(site)
    print("cwd: " + Dir.getwd + "\n")
    checkout_path = File.join(Dir.getwd, site.config['checkout_path'])
    print("checkout path: " + checkout_path + "\n")

    # get the collection of repos
    repos = site.collections['repos']
    #print("repos: " + repos.inspect + "\n")

    # clone or update each repo
    repos.docs.each do |repo|
      # check if the repo is already cloned
      local_path = File.join(checkout_path, repo.data['name'])

      g = nil
      unless File.exist?(local_path)
        # initialize a new local repo
        print("initializing local repo: " + repo.data['name']+"\n")
        g = Git.init(local_path)
      else
        print("opening existing local repo: " + repo.data['name']+"\n")
        # open existing local repo
        g = Git.open(local_path)
      end

      # fetch all the instances
      repo.data['instances'].each do |instance|
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
          remote_name = make_remote_name(instance['type'], instance['ns'], instance['name'])
          print("adding remote "+remote_name+" from: " + uri + "\n")
          remote = g.add_remote(remote_name, uri)
        end

        # fetch the remote
        print("fetching remote "+remote.inspect+" from: " + remote.url + "\n")
        g.fetch(remote)
      end

      # get branches corresponding to ros distros
      distro_branches = Hash.new {|h,k| h[k]=[]}
      g.branches.each do |branch|
        branch_tail = branch.to_s.split('/')[-1]
        print(" - branch: " + branch.inspect + " "+branch_tail+"\n")

        site.config['distro_tokens'].each do |distro|
          if branch_tail.include? distro
            distro_branches[distro] << branch
          end
        end
      end
      
      # get README.md files from all branches

      print("distro branches: " + distro_branches.inspect + "\n")
      

      #site.pages << RepoPage.new(...)
    end
  end
end

class RepoPage < Jekyll::Page
  def initialize(site, base, dir, name)
    super(site, base, dir, name)
    # clone (or update) git repo
    # for each ROSDISTRO-devel branch
    # list all ROS packages in the repo
    #site.pages << PackagePage.new(...)
  end
end

class PackagePage < Jekyll::Page
  def initialize(site, base, dir, name)
    super(site, base, dir, name)
  end
end

