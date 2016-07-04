---
layout: post
title: "Cloud Services and Bountysource Campagin"
---

You might know that ROS Index is a static site, and for the last year, it has been generated on one or more privately-owned workstations. Supporting this manner of site generation is neither scalable nor robust. To improve the process, we have switched to using [Google Compute Engine](https://cloud.google.com/compute/) for generating the site. This makes it significantly easier to maintain and manage the site for a reasonable cost.

ROS Index has also migrated from an in-browser JavaScript-based search (lunr.js) to a Google Custom Search Engine (CSE). ROS Index is still being crawled, but this search should make it easier to find packages and repositories. In the future we will add semantic labels to package pages to make the Google CSE even more powerful.

To support these services, as well as general ROS Index development, we have created a Bountysource Campagain to improve the website. Support for ROS Index will directly improve the value of the site by increasing the crawl frequency and providing funds for maintenance and new features. If you value ROS Index and want to see it improved, even $1 USD per month can help!

<a href="https://salt.bountysource.com/teams/rosindex" target="_blank" class="btn btn-success">Support ROS Index on Bountysource!</a>
