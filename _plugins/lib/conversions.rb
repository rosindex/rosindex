# Tools for parsing and converting data

require 'open3'
require 'json'

def get_hdf(hdf_str)
  # convert some hdf garbage into a ruby structure SUPERHACK
  # HDF is an old mostly unused markup format which is used to describe ROS
  # APIs on the ROS Wiki
  stdin, stdout, stderr = Open3.popen3('_scripts/hdf2json.py')
  stdin.puts(hdf_str)
  return JSON.parse(stdout.gets)
end

