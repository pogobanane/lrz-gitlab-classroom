# Minimal Classroom for LRZ's GitLab

## Maintain

If things don't work:

- Check if github token is expired after a year.


## Lecturer Usage

{"c":"17W","g":46686,"l":"950798529","r":97579,"t":97841}

where l is the lecture id


## Design

The system consists of two parts. A perl-based website, and a python-based worker/backend. Students receive a (possibly) unique sign-up link to sign up. After signup, the website stores the user info in the state dir mojo.db. The python worker monitors files in the state dir for changes, pops the new users out of mojo.db, and creates the student repositories on gitlab accordingly.


## Safety

Ensure that the following is given for compliance with campus.tum.de OAuth.

- Bestätigung dass die Anwendung ausschließlich über https:// mit HSTS erreichbar ist
- Bestätigung dass die Anwendung angemessenen Schutz vor Cross-Site Request-Forgery mitbringt, insbesondere Verknüpfung und Validierung des OAuth "state" Parameters mit der Nutzer-Session. Fehlende Validierung des "state" Parameters erlaubt das Unterschieben fremder Nutzer-Sessions!
- Bestätigung dass die Anwendung keine Einbettung in Frames gestattet (X-Frame-Options oder Content-Security-Policy Header)


## TODO

- Document example environment file
