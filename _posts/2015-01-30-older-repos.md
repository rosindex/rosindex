---
layout: post
title: "Better Support for Older Repos"
---

There were previously a few thousand older ROS packages which weren't being
indexed because they were referenced by old (read: bad) svn repo checkout URIs.
This has now been fixed, and now there are many more older repositories from
ROS Fuerte and ROS Electric in the index.

A new [Errors Page](/stats/errors/) also now shows errors encountered while
indexing. If you expect to see something in the index and it isn't there, this
page might shed some light on it.
