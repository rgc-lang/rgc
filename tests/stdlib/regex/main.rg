import regex

def main() -> int {
    rx = regex.compile("a+b")
    print("ok", rx.ok)
    print("lit", regex.is_match(@rx, "aaab"))
    print("search", regex.is_match(@rx, "xxaaab"))
    print("miss", regex.is_match(@rx, "xx"))
    print("find", regex.find(@rx, "xxaaab"))
    print("find_no", regex.find(@rx, "zzz"))
    print("repl", regex.replace(@rx, "caaabd", "-"))

    alt = regex.compile("cat|dog")
    print("alt", regex.is_match(@alt, "hotdog"), regex.is_match(@alt, "bird"))

    grp = regex.compile("^(ab)+c?$")
    print("grp", regex.is_match(@grp, "ababc"), regex.is_match(@grp, "abx"))

    dot = regex.compile("h.llo")
    print("dot", regex.is_match(@dot, "hello"), regex.is_match(@dot, "hllo"))

    cls = regex.compile("[a-z0-9_]+")
    print("cls", regex.is_match(@cls, "abc_123"), regex.is_match(@cls, "ABC"))
    neg = regex.compile("[^0-9]+")
    print("neg", regex.is_match(@neg, "abc"), regex.is_match(@neg, "123"))

    esc = regex.compile("\\d+\\s\\w+")
    print("esc", regex.is_match(@esc, "42 ok"), regex.is_match(@esc, "x 42"))

    anch = regex.compile("^abc$")
    print("anch", regex.is_match(@anch, "abc"), regex.is_match(@anch, "xabc"))

    opt = regex.compile("colou?r")
    print("opt", regex.is_match(@opt, "color"), regex.is_match(@opt, "colour"), regex.is_match(@opt, "colouur"))

    star = regex.compile("a*")
    print("star", regex.is_match(@star, ""), regex.is_match(@star, "ba"))

    rep = regex.compile("^a{2,3}$")
    print("rep", regex.is_match(@rep, "aa"), regex.is_match(@rep, "aaa"),
          regex.is_match(@rep, "a"), regex.is_match(@rep, "aaaa"))
    rep2 = regex.compile("^a{2}$")
    print("rep2", regex.is_match(@rep2, "aa"), regex.is_match(@rep2, "aaa"))
    rep3 = regex.compile("^a{2,}$")
    print("rep3", regex.is_match(@rep3, "a"), regex.is_match(@rep3, "aa"),
          regex.is_match(@rep3, "aaaa"))
    rep4 = regex.compile("^ab{0,2}c$")
    print("rep4", regex.is_match(@rep4, "ac"), regex.is_match(@rep4, "abbc"),
          regex.is_match(@rep4, "abbbc"))

    bound = regex.compile("\\bcat\\b")
    print("bound", regex.is_match(@bound, "a cat!"), regex.is_match(@bound, "concat"))
    nonbound = regex.compile("\\Bcat\\B")
    print("nonbound", regex.is_match(@nonbound, "concatenate"), regex.is_match(@nonbound, "cat"))

    empty = regex.compile("")
    print("empty", empty.ok, regex.find(@empty, "xyz"), regex.replace(@empty, "ab", "-"))

    bad = regex.compile("a(b")
    print("bad", bad.ok, bad.error)
    bad2 = regex.compile("[z-a]")
    print("bad2", bad2.ok, bad2.error)
    bad3 = regex.compile("a{3,1}")
    print("bad3", bad3.ok, bad3.error)
    bad4 = regex.compile("a{2")
    print("bad4", bad4.ok, bad4.error)
    badref = regex.compile("\\1(a)")
    print("badref", badref.ok, badref.error)
    badgrp = regex.compile("(?=a)")
    print("badgrp", badgrp.ok, badgrp.error)

    cap = regex.compile("(\\d+)-(\\d+)")
    cm = regex.search(@cap, "x 12-34 y")
    print("cap", cm.ok, cm.start, cm.end, cm.groups.get(0),
          cm.groups.get(1), cm.groups.get(2))
    nom = regex.search(@cap, "abc")
    print("nomiss", nom.ok, nom.start, nom.groups.len())

    cap2 = regex.compile("(a)(b)?")
    cm2 = regex.search(@cap2, "xa")
    print("cap2", cm2.ok, cm2.groups.get(0), cm2.groups.get(1),
          "[" + cm2.groups.get(2) + "]")
    cm2b = regex.search(@cap2, "xab")
    print("cap2b", cm2b.groups.get(0), cm2b.groups.get(2))

    nest = regex.compile("((a)(b))")
    nm = regex.search(@nest, "zab")
    print("nest", nest.ngroups, nm.groups.get(1), nm.groups.get(2), nm.groups.get(3))

    repc = regex.compile("(a|b)+")
    rm = regex.search(@repc, "xab!")
    print("repc", rm.groups.get(0), rm.groups.get(1))

    nc = regex.compile("(?:ab)+(c)")
    ncm = regex.search(@nc, "ababc")
    print("nc", nc.ngroups, ncm.groups.get(0), ncm.groups.get(1))

    back = regex.compile("(cat)\\s\\1")
    print("back", regex.is_match(@back, "cat cat"), regex.is_match(@back, "cat dog"))
    bm = regex.search(@back, "a cat cat!")
    print("backm", bm.ok, bm.start, bm.end, bm.groups.get(1))

    b2 = regex.compile("(\\w)\\1")
    print("back2", regex.find(@b2, "hello"), regex.is_match(@b2, "abc"))

    b3 = regex.compile("(a+)-\\1")
    b3m = regex.search(@b3, "aa-aa")
    print("back3", b3m.ok, b3m.groups.get(1))

    b4 = regex.compile("(a+)\\1")
    b4m = regex.search(@b4, "aaaa")
    print("back4", b4m.ok, b4m.groups.get(1), b4m.end)

    b5 = regex.compile("(a)?\\1")
    print("back5", regex.is_match(@b5, ""), regex.is_match(@b5, "b"))

    lazy1 = regex.compile("a+?")
    lm = regex.search(@lazy1, "aaa")
    print("lazy1", lm.groups.get(0), regex.replace(@lazy1, "aaa", "-"))
    lazy2 = regex.compile("a{1,3}?")
    lm2 = regex.search(@lazy2, "aaaa")
    print("lazy2", lm2.groups.get(0))
    greedy2 = regex.compile("a{1,3}")
    gm2 = regex.search(@greedy2, "aaaa")
    print("greedy2", gm2.groups.get(0))
    lazy3 = regex.compile("<(.+?)>")
    lm3 = regex.search(@lazy3, "<a><b>")
    print("lazy3", lm3.groups.get(0), lm3.groups.get(1))
    greedy3 = regex.compile("<(.+)>")
    gm3 = regex.search(@greedy3, "<a><b>")
    print("greedy3", gm3.groups.get(0), gm3.groups.get(1))
    lazyq = regex.compile("ab??")
    lq = regex.search(@lazyq, "ab")
    print("lazyq", lq.groups.get(0))
    lazystar = regex.compile("a*?b")
    ls = regex.search(@lazystar, "aaab")
    print("lazystar", ls.groups.get(0))

    many = regex.compile("((((((((((a))))))))))\\10")
    print("many", many.ok, many.ngroups, regex.is_match(@many, "aa"))

    emptym = regex.compile("(a*)\\1")
    em = regex.search(@emptym, "")
    print("emptym", em.ok, "[" + em.groups.get(0) + "]", "[" + em.groups.get(1) + "]")

    altp = regex.compile("(a|ab)")
    am = regex.search(@altp, "ab")
    print("altcap", am.groups.get(0), am.groups.get(1), regex.replace(@altp, "ab", "-"))

    sub = regex.compile("(\\w+)@(\\w+)")
    print("sub", regex.replace(@sub, "user@host", "$2:$1"))
    print("sub2", regex.replace(@sub, "a@b c@d", "${2}-$1-$0"))
    print("sub3", regex.replace(@sub, "a@b", "$$1"))
    print("sub4", "[" + regex.replace(@sub, "a@b", "$3") + "]")
    return 0
}
