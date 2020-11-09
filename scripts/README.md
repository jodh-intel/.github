# Scripts

## Hub utility tool

`hub-util.sh` is a script that expands the abilities of GitHub's excellent
[`hub`](https://github.com/github/hub) tool.

### Full details

Lists all available options:

```sh
$ hub-util.sh -h
```

## PR porting checks

The `pr-porting-checks.sh` script checks a PR to ensure it follows the PR
porting policy. It is designed to be called from a GitHub action.

### Full details

Lists all available options:

```sh
$ pr-porting-checks.sh -h
```

## Find porting PRs

Script to find port PRs. Run from the top-level directory of a repository with
no arguments to look for all back and forward port PRs.

See the
[porting documentation](https://github.com/kata-containers/community/blob/master/CONTRIBUTING.md#porting)
for further details.

### Full details

Lists all available options:

```sh
$ kata-github-find-porting-prs.sh -h
```
