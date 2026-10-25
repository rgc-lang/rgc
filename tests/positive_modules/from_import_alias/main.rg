# from-import: names take effect + as aliases; the un-imported whisper is still available via qualified calls
from mystr import shout, whisper as low

def main() {
    print(shout("hey"))
    print(low("sssh"))
    print(mystr.whisper("qual"))
}
