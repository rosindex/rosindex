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
layout: repo
title: conman
permalink: repos/conman
tags: [control, orocos, realtime, controller]
instances:
- {type: 'github', org: 'jbohren', repo: 'conman', tut:'doc/tutorials' }
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
