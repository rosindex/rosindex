module Jekyll
  class GitScraper < Generator
    def generate(site)
      site.pages << RepoPage.new(...)
    end
  end

  class RepoPage < Page
    def initialize(site, base, dir, name)
      super(site, base, dir, name)
      # clone (or update) git repo
      # for each ROSDISTRO-devel branch
        # list all ROS packages in the repo
        site.pages << PackagePage.new(...)
    end
  end

  class PackagePage < Page
    def initialize(site, base, dir, name)
      super(site, base, dir, name)
    end
  end

end
