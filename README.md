# Minimal Classroom for LRZ's GitLab

## Maintain

If things don't work:

- Check if github token is expired after a year.


## Design

The system consists of two parts. A perl-based website, and a python-based worker/backend. Students receive a (possibly) unique sign-up link to sign up. After signup, the website stores the user info in the state dir. The python worker monitors files in the state dir for changes, and creates the student repositories on gitlab accordingly.
