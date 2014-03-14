# 0.2.1 (unreleased)

* Confirm before destroying server
* HandleBox before validate on box startup.
* Use fog-brightbox module to reduce dependencies.

# 0.2.0 (April 19, 2013)

* Merge from upstream 'vagrant-aws' v0.2.2
* Ability to specify a timeout for waiting for server to build.
* Add support for `vagrant ssh -c`
* Better error messages if server doesn't build in time.
* Implement `:disabled` flag support for shared folders.
* `brightbox.user_data` to specify user data on the server.

# 0.1.0 (April 15, 2013)

* Exclude the ".vagrant" directory from rsync.
* Initial release.
