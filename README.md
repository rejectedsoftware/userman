UserMan - A User Management System
==================================

<img src="https://github.com/rejectedsoftware/userman/blob/master/public/images/logo-256.png" align="left">
This package doubles as a library that provides an embeddable user management
interface for websites and as a standalone server that provides a user
administration front end, as well as a RESTful service that can be used for
authentication or to manage user accounts.

A major revision of the source code is currently underway. More instructions
will be added in that process.

[![Build Status](https://travis-ci.org/rejectedsoftware/userman.svg?branch=master)](https://travis-ci.org/rejectedsoftware/userman)


Migration notes for 0.3.x to 0.4.x
----------------------------------

In 0.4.x, the database layout for storing groups has changed and will be
migrated automatically on the first run. Care should be taken to not run 0.3.x
afterwards, as that will lead to exceptions if groups are used. Data corruption
on the other hand should not happen.
