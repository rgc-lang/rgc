# Negative test: accessing a module's private type
import priv

def main() {
    h = Hidden()
    h.x = 5
}