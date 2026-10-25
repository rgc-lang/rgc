import string
import list
import path

def main() -> int {
    s = "  Hello RGC  "
    print("trim=[" + string.trim(s) + "]")
    print("find =", string.find(s, "RGC"))
    print("replace =", string.replace("a-b-c", "-", "+"))
    print("upper =", string.to_upper("Abc"))
    print("lower =", string.to_lower("AbC"))
    print("pad =", string.pad_left("7", 3, "0"))

    xs = List[int]()
    xs.push(3)
    xs.push(1)
    xs.push(2)
    print("sum =", list.sum_ints(@xs))
    print("min/max =", list.min_int(@xs), list.max_int(@xs))
    list.sort_ints(@var xs)
    print("sorted =", list.join_ints(@xs, ","))
    list.reverse_ints(@var xs)
    print("rev =", list.join_ints(@xs, ","))

    names = List[str]()
    names.push("bob")
    names.push("alice")
    names.push("carol")
    list.sort_strs(@var names)
    print("names =", ",".join(names))

    print("path =", path.join("a", "b"))
    print("base =", path.basename("/x/y.txt"))
    print("dir =", path.dirname("/x/y.txt"))
    print("ext =", path.extension("/x/y.txt"))
    print("stem =", path.stem("/x/y.txt"))
    return 0
}
