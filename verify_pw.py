from passlib.hash import sha512_crypt
import getpass
import sys

print(sha512_crypt.verify(getpass.getpass(), sys.argv[1]))
