# Server signing (sign-api.js)

zsign on this machine, run by a chain of core-pinned workers. The Uncrypt app sends a job, follows the log, and
installs the result over the air from this domain.

## 1. Files

Copy `sign-api.js` next to `site.js` (the same folder as `dtx-api.js` and `plugins.js`).

zsign and the work folder are already in place if you ran the install commands:

    /usr/local/bin/zsign          zsign 1.1.3
    /var/lib/dct-sign             owned by dct, mode 700

## 2. Mount it in site.js

Add this after the line that creates `dtx` (it uses the same helpers `plugins.js` is mounted with):

    require("./sign-api.js")({ app, express, limited, fail, okOrigin, env: process.env, SITE_URL, dtx, isStaff });

`isStaff` is the same function you pass to `dtx-api.js` (it is called with "u<id>"). Leave `dtx` out to sign for free.

Then restart the site:

    runuser -u dct -- pm2 restart all

On start it prints the workers and their cores, for example:

    Sign: 8 workers, cores 0,1,16,17 | 2,3,18,19 | ...

## 3. The install links must be reachable without a login

iOS downloads the manifest and the IPA by itself, with no cookie and none of the app's headers:

    GET /api/sign/dl/<token>/manifest.plist
    GET /api/sign/dl/<token>/app.ipa

If `site.js` has a rule that blocks `/api/*` requests without a session or without the `x-dt` header, let
`/api/sign/dl/` through. The 48-character random token in the link is what protects them.

## 4. Settings (environment, all optional)

    SIGN_CORES       cores per worker, workers separated by ";"   e.g. 0-1,16-17;2-3,18-19
                     default: two physical cores plus their hyperthreads per worker, read from the CPU layout
    SIGN_KEEP_MIN    minutes a signed IPA stays installable        default 30
    SIGN_MAX_MB      largest IPA the server will fetch             default 4096
    SIGN_MAX_QUEUE   jobs that may wait                            default 40
    SIGN_JOB_MIN     minutes before a stuck zsign is stopped       default 15
    SIGN_DIR         work folder                                   default /var/lib/dct-sign
    SIGN_ZSIGN       path to zsign                                 default /usr/local/bin/zsign
    SIGN_TASKSET     "0" turns pinning off                         default taskset

## 5. What it costs and what it keeps

- A job costs `prices.sign` DTX (3 by default), refunded if signing fails. Staff sign free.
- The .p12, its password and the profile are deleted the moment zsign exits. The password is passed to zsign on its
  command line, so while a job runs it is visible in the process list to users on this machine.
- The signed IPA is deleted after SIGN_KEEP_MIN minutes. Jobs are held in memory, so a restart drops them and clears the folder.
- The server only fetches IPAs over https from public addresses.
