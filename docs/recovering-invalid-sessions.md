# Recovering an invalid session

The label stage (`assign`) gives each session three IDs: the project, the
subject and the session. It reads each ID from the DICOM tag that
`ingest.assign.tagMapping` names. `ingest.assign.constantProjectId` can set the
project instead. When a tag that the stage reads is empty, the stage cannot
name the session. It moves the session to `/data/assigned/__invalid__/` on the
node and does not upload it. This page tells you how to move the session back
after a person finds the missing value.

The stage behaviour (the log line, the alert, what happens to the Orthanc,
grouped and backup copies) is in
[components/accessionflow.md](components/accessionflow.md#recovering-an-invalid-session).

## What you see

- The alert `InvalidSessionAssigned` fires. It counts log lines, not sessions.
  It clears when no new line of this type came in the last 10 minutes, so more
  invalid sessions keep it on. A clear alert does not mean that the session was
  recovered.
- The folder name shows the missing ID:
  `<project>.<subject>.INVALID_MISSING_<FIELD>_<suffix>`, for example
  `test_project.MRN1.INVALID_MISSING_ACCESSIONNUMBER_ognMmX8R`.
- Nothing removes the folder. Do not delete it to clear the alert. It can be
  the only copy of the study. The facility backup keeps only the instances that
  came in by DICOM, and a backup write can fail.
- More data for the study can come later, for example a late series. The
  assign log then says `already saved as invalid` on each pass. See
  [More data for the same study](#more-data-for-the-same-study).

## Who does what

| Who | Does | Needs |
|---|---|---|
| The operator | Gets the alert. Runs `list` and `show`. Runs `requeue` with the value. | One of the methods below |
| A person with the hospital's records (a clinician or a data manager) | Finds the missing value in the RIS or the PACS, from the details that `show` prints | No access to the node |

Nothing finds the value for you: the DICOM tag was empty. The tool never
guesses it.

## The procedure

1. Run `list`. It shows each folder in `__invalid__/` and the missing ID.
2. Run `show <folder>`. It prints the study details: PatientID, the study date
   and time, the description, the modality, the AccessionNumber and the
   StudyInstanceUID. These are patient data. Keep them on the terminal.
3. Give the details to the person with the hospital's records. That person
   finds the missing value.
4. Make sure that the XNAT project has no session with the new label. XNAT
   keeps each session label once in a project, and the upload refuses a label
   that another subject already has (see [After the move](#after-the-move)).
5. Run `requeue <folder> --session <value>`. Give `--project`, `--subject` or
   `--session` for each ID that the folder misses, and only for those.
6. Look for the session in the upload log (`<release>-upload`), then in XNAT.

Use one of the methods below for steps 1, 2 and 5. All of them run the same
tool, except the manual fallback.

### Example

From a test run, with method 1. The values are synthetic.

```console
$ sudo ais-requeue list
folder                                                                       missing                  files  age
test_project.MRNAFK3-20261110152854.INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK session=ACCESSIONNUMBER  20     0.0h
```

`<folder>` is the name in the first column. It is a name, not a path. Copy it
whole.

```console
$ sudo ais-requeue show test_project.MRNAFK3-20261110152854.INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK
folder:   test_project.MRNAFK3-20261110152854.INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK
labels:   project=test_project, subject=MRNAFK3-20261110152854, session=INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK
missing:  session (DICOM ACCESSIONNUMBER)
Look up the missing value with these study details (patient data: keep it on this terminal):
  PatientID          MRNAFK3-20261110152854
  StudyDate          20260909
  StudyTime          040041
  StudyDescription   test_project
  Modality           MR
  AccessionNumber    (empty)
  StudyInstanceUID   1.2.826.0.1.3680043.8.498.12268812667897551533890468604834365304
```

The session ID is missing. The person with the hospital's records finds the
AccessionNumber of this study, here `ACCK320261110152854`. Give it with
`--session`:

```console
$ sudo ais-requeue requeue test_project.MRNAFK3-20261110152854.INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK --session ACCK320261110152854
{"ts": "2026-11-10T15:36:43Z", "event": "invalid_requeued", "operator": "ubuntu@k0s-edge-worker-dev", "from": "test_project.MRNAFK3-20261110152854.INVALID_MISSING_ACCESSIONNUMBER_JQWrfStK", "to": "test_project.MRNAFK3-20261110152854.ACCK320261110152854", ...}
requeued: assigned/test_project.MRNAFK3-20261110152854.ACCK320261110152854. Next: watch the uploader log for this session, then check it in XNAT.
```

The folder now has the name `<project>.<subject>.<session>`. The upload sends
it to XNAT with the session label `ACCK320261110152854`. When more data for the
study waits in `grouped/`, a `NOTE:` line follows. See
[More data for the same study](#more-data-for-the-same-study).

## Choose a method

| Method | Where you run it | You need | sudo |
|---|---|---|---|
| [1. The node command](#method-1-the-node-command) | The node | sudo on the node | Yes |
| [2. The node command, sudo for this command only](#method-2-the-node-command-with-sudo-for-this-command-only) | The node | A sudo rule that an admin adds once | Only for this command |
| [3. kubectl](#method-3-kubectl) | The node, or a machine with a kubeconfig for the cluster | kubectl and permission to exec into the label pod | No |
| [4. The repository script](#method-4-the-repository-script) | The repository clone on the node | The same as method 3 | No |
| [5. By hand](#method-5-by-hand-the-fallback) | The node | sudo on the node | Yes |

## Method 1: the node command

Run these commands on the node:

```bash
sudo ais-requeue list
sudo ais-requeue show <folder>
sudo ais-requeue requeue <folder> --session <value>
```

You need no kubectl and no copy of this repository. The command needs root,
because k0s's container runtime accepts only root.

If the release is not in the namespace `xnat-ingest`, give the namespace
first:

```bash
sudo ais-requeue --namespace <namespace> list
```

### Install the node command

`install.sh` installs `/usr/local/bin/ais-requeue`. When sudo asks for a
password, it does not wait: it prints the one command to run by hand.

A node installed before the command existed does not have it. Install it once,
from the repository clone on the node:

```bash
sudo install -o root -g root -m 0755 scripts/files/ais-requeue /usr/local/bin/ais-requeue
```

Do the same to update the command. The tool in the label pod comes from the
chart, so a chart upgrade updates the tool.

## Method 2: the node command with sudo for this command only

Use this method when an operator must not have full sudo on the node. An
admin lets a group run `/usr/local/bin/ais-requeue` as root, and nothing else.

The admin does these steps once, on the node:

1. Make the group:

   ```bash
   sudo groupadd ais-requeue
   ```

2. Add the operator to the group. The operator must log in again.

   ```bash
   sudo usermod -aG ais-requeue <user>
   ```

3. Add the sudo rule, and check it:

   ```bash
   echo '%ais-requeue ALL=(root) /usr/local/bin/ais-requeue' | sudo tee /etc/sudoers.d/ais-requeue
   sudo chmod 0440 /etc/sudoers.d/ais-requeue
   sudo visudo -cf /etc/sudoers.d/ais-requeue
   ```

The operator then uses the commands of method 1. sudo asks for the operator's
own password. Add `NOPASSWD:` before the path if the site does not want that.

This rule is safe for this command. The node command sets the pipeline folder
(`--root`) and the operator name (`--operator`) itself. The first word must be
`list`, `show` or `requeue`. So no option can come before it. The tool refuses
an option that it does not know. The folder must be a name as `list` prints it.
The tool refuses a path (a `/`), `.`, `..` and a symbolic link, and it checks
that the real path is in `__invalid__/`. So the operator cannot point the tool
at another folder. The audit line always names the real user (from
`SUDO_USER`).

## Method 3: kubectl

Use this method where kubectl can reach the cluster: on the node, `install.sh`
sets up kubectl with `$HOME/.kube/config`. You need no sudo.

```bash
kubectl -n xnat-ingest exec deploy/<release>-assign -c assign -- \
  python3 /opt/ais-edge/requeue-invalid.py --operator <your-name> list
```

Use `show <folder>` and `requeue <folder> --session <value>` in place of
`list`. Give your name with `--operator`: the audit line records it.

The kubeconfig must allow `get` on pods and deployments, and `create` on
`pods/exec`, in the namespace. That permission lets a user run any command in
any pod of the namespace. Give it only to operators who can see the pipeline
data.

## Method 4: the repository script

From the repository clone, `scripts/requeue-invalid.sh` runs method 3 for you.
It finds the label pod and records `<user>@<host>` as the operator.

```bash
scripts/requeue-invalid.sh list
scripts/requeue-invalid.sh show <folder>
scripts/requeue-invalid.sh requeue <folder> --session <value>
```

`--namespace <namespace>` selects another namespace, and `--kubeconfig <file>`
another kubeconfig.

## Method 5: by hand (the fallback)

Use this method only when the tool cannot run. It does the same move without
the checks of the tool, and it does not take the label stage's lock.

On the node, rename the folder to `<project>.<subject>.<session>` and move it up
into `assigned/`. `/data` is the pipeline hostPath, `/data/xnat-ingest`
by default. The commands stop if a folder of that name exists. `mv -nT` never
replaces a folder and never moves into one. The last `test` checks that the
folder really left `__invalid__/`:

```bash
cd /data/xnat-ingest/assigned
sudo test ! -e <project>.<subject>.<session> \
  && sudo mv -nT __invalid__/<folder> <project>.<subject>.<session> \
  && sudo test ! -e __invalid__/<folder> \
  && sudo ls -d <project>.<subject>.<session>
```

If a check fails, look at both paths and the stage logs before you do anything
else. A session with that name can already wait, or the next stage can already
have taken the moved folder. Never repeat the move blindly.

## What requeue checks

`requeue` refuses, and moves nothing, when:

- the folder is not a name as `list` prints it: a path (a `/`), `.` or `..`,
  or a symbolic link. `show` refuses these too;
- a part of the folder name has a character that is not a letter, a digit,
  `_` or `-`. The new name keeps the parts that are not missing, so they must
  be legal labels. Use [method 5](#method-5-by-hand-the-fallback) for this
  folder;
- a value is not a legal label: use letters, digits, `_` and `-` only;
- you give a value for an ID that is not missing, or you do not give a missing
  one;
- `assigned/<new name>` or `deidentified/<new name>` already exists. If the
  session in `deidentified/` is the same study (more data for it), add
  `--allow-existing`. A folder that waits in `assigned/` is never merged. Wait
  until that session moves on, then run the command again.

`requeue` does not refuse when a `grouped/` copy of the same study waits. It
moves the folder and prints a `NOTE`. See
[More data for the same study](#more-data-for-the-same-study).

It moves the folder under the label stage's lock
(`/data/.locks/assigned.lock`), so a label pass cannot run at the same time.
It checks that the folder left `__invalid__/`. It adds one line for each move
to `/data/LOGS/requeue-audit.jsonl`: who, when, the old and the new name, and
the values given.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | The folder moved |
| 2 | Refused, or a wrong command. The message tells why |
| 3 | No such folder in `__invalid__/` |
| 4 | A label pass holds the lock. Try again |

## After the move

The upload takes the three IDs from the folder name. Do not edit the files. No
method changes the DICOM files. Under `deid.engine: ingest`, the deidentify
stage takes the session from `assigned/` first, as for any other session.

Look for the session in the upload log, then in XNAT. When the data policy is
armed, the reclaimer removes the local copy after XNAT holds every file.

Do not send the study again to correct it. Orthanc keeps the instances that it
already has, and it ignores a copy with the same SOPInstanceUID.

If XNAT already has a session with the new label under another subject, the
upload refuses the session. On each pass, the upload log (`<release>-upload`)
says `Cannot verify XNAT session identity`, and `XNATUploadRetryStorm` fires.
The session waits in the upload tree. The staged reclaimer keeps it there,
because XNAT does not confirm it. There is no command yet to change the label
of a session after it left `__invalid__/`. Do not remove that copy, and ask the
maintainers of this repository.

## More data for the same study

More data for a study can come while the study is in `__invalid__/`, for
example a late series. collate puts it in `/data/grouped/_.<study UID>`. For a
study from Orthanc, that copy holds the whole study again.

The label stage does not take this copy while the study is in `__invalid__/`.
On each pass, its log says `already saved as invalid`. So the copy does not
clear by itself. Do not remove it: it can hold instances that are not in
`__invalid__/`.

1. Requeue the folder in `__invalid__/` as usual. `requeue` moves it and
   prints a `NOTE` that names the `grouped/` copy. The audit line names the
   copy in `grouped_waiting`.
2. On its next pass, the label stage puts the `grouped/` copy in a new folder
   in `__invalid__/`. `InvalidSessionAssigned` fires again.
3. Run `list`. Requeue the new folder with the same values:
   - When `assigned/<new name>` is still there, the command refuses: a folder
     cannot be merged into it. Run the command again after that session moves
     on (deidentify takes it, or the data policy removes it after the upload).
   - When `deidentified/<new name>` is there, add `--allow-existing`.
4. The new data goes to the same session in XNAT, as a late series does.

## How the tool reaches the node

- The label pod runs the accessionflow image. This chart does not change that
  image. It mounts one more file into the container: the ConfigMap
  `<release>-requeue-tool`, made from `charts/edge/files/requeue-invalid.py`,
  read-only at `/opt/ais-edge`. The tool runs with the `python3` of the image.
  It is a directory mount, so a chart upgrade updates the file without a
  restart of the stage.
- The node command, `scripts/files/ais-requeue`, is a short shell script. It
  finds the label container that runs (`k0s ctr`: the container name `assign`,
  the namespace, and a task in the state RUNNING). It then runs the tool in
  that container. It gives back the exit code of the tool.
- `scripts/requeue-invalid.sh` runs the same tool with kubectl.
