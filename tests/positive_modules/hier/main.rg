# Directory hierarchy: import net/tcp binds the last segment tcp; as overrides the binding name;
# geom/mod.rg is a directory module; from a hierarchical path imports a type
import os
import net/tcp
import net/tcp as nt
import geom
from net/tcp import Conn

def main() {
    if tcp.ping() != 42 {
        os.exit(1)
    }
    if nt.ping() != 42 {
        os.exit(1)
    }
    if tcp.pick(7) != 7 {
        os.exit(1)
    }
    if geom.area(3, 4) != 12 {
        os.exit(1)
    }
    c = Conn()
    c.port = 10
    if connect(c) != 11 {
        os.exit(1)
    }
}
