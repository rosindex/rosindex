
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
      # iterate over instances
      repo.data['instances'].each do |instance|
        # create page for this repo
        uri = github_uri(instance['ns'], instance['name'])

        # check if the repo is already cloned
        local_path = File.join(checkout_path, repo.data['name'])

        g = nil
        unless File.exist?(local_path)
          # clone a new repo
          print("initializing repo: " + repo.data['name']+"...\n")
          g = Git.init(local_path)
        else
          g = Git.open(local_path)
        end

        # check if this remote exists
        print("remotes: " + g.remotes.inspect + "\n")
        remote_found = false
        g.remotes.each do |remote|
          print("remote: "+ (remote.to_s) +"\n")
          if remote.url == uri
            # if this remote exists, fetch it
            print("fetching remote "+remote.inspect+" from: " + remote.url + "\n")
            g.fetch(remote)
            remote_found = true
          end
        end

        # add the remote if it isn't found
        unless remote_found
          new_remote_name = make_remote_name(instance['type'], instance['ns'], instance['name'])
          print("adding remote "+new_remote_name+" from: " + uri + "\n")
          remote = g.add_remote(new_remote_name, uri)
          print("fetching remote "+remote.inspect+" from: " + remote.url + "\n")
          g.fetch(remote)
        end

      end


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

