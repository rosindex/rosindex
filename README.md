ROS Index
=========

A simple index for known ROS packages on GitHub. It builds in jekyll with a
plugin to pull down information from github, and uses client-side javascript to
fetch additional information from GitHub like open tickets and forks.

## Contributing

### Repositories

Repositories are described in YAML-annotated markdown files in the `_repos`
directory. Each repo file describes one or more version-control repositories.
Multiple repositories with different versionf of the code can be listed under
`instances`.

```yaml
name: conman
default: jbohren
instances:
  jbohren: {type: 'github', org: 'jbohren', repo: 'conman', tut:'doc/tutorials' }
```

### Package Metadata

Catkin `package.xml` files can be augmented with `<rosindex>` tags in the `<export>` section.

#### Tags

```xml
<package>
  <!-- ... -->

  <export>
    <rosindex>
      <tags>
        <tag>biped</tag>
        <tag>planning</tag>
      </tags>
    </rosindex>
  </export>
</package>
```

## Presentation

### Versioning

The user selects the rosdistro they're interested in from a global drop-down
list. This sets a client-side cookie which will persist.

### Tutorials

## Building

```
jekyll build
```

## Deployment

Since this needs to do a lot of heavy lifting to generate the site, it needs to
be deployed from a fully-equipped environment.

```
git checkout source
jekyll build
git branch -D master
git checkout -b master
git add -f _site
git commit -m "deploying"
git filter-branch --subdirectory-filter _site/ -f
git push -f origin master
git checkout source
```

