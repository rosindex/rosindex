#!/usr/bin/env python

from __future__ import print_function

import fileinput
import json
import neo_cgi
from neo_util import HDF

def hdf2dict(hdf_as_str):
    """
    Usage
    >>> json_data = hdf2json('''artists {
    ... 0 {
    ... name = Persuader, The
    ... }
    ... }
    ... title = Stockholm
    ... labels {
    ... 0 {
    ... name = Svek
    ... catno = SK032
    ... }
    ... }''')
    """

    if not isinstance(hdf_as_str, basestring):
        raise ValueError('argument must be a string')

    hdf_obj = HDF()
    hdf_obj.readString(hdf_as_str)

    node = hdf_obj

    def traverse_node(node):
        dict_part = {}
        list_part = []

        while node and node.name().isdigit():
            if node.value():
                list_part.append(node.value())
            else:
                list_part.append(traverse_node(node.child()))
            node = node.next()

        if list_part:
            return list_part

        while node:
            if node.value() is not None and not node.child():
                val = node.value()
                dict_part[node.name()] = val
            else:
                dict_part[node.name()] = traverse_node(node.child())
            node = node.next()

        return dict_part

    return traverse_node(node.child())


def hdf2json(hdf_as_str):
    return json.dumps(hdf2dict(hdf_as_str))

def main():
    s = ''
    for line in fileinput.input():
        # freaking hdf can't handle multiple braces on one line
        s += line.replace('}',"}\n\r")

    print(hdf2json(s))

if __name__ == "__main__":
    #import doctest
    #doctest.testmod()
    main()
