def plat_tool(name):
    native.genrule(
        name = name,
        srcs = select({
            ':osx': [ 'osx/' + name ],
            '//conditions:default': [ 'linux/' + name ],
        }),
        outs = ['bin/' + name ],
        cmd = 'cat $< > $@',
        executable = True,
        output_to_bindir = True,
        visibility = ['//visibility:public'],
    )
