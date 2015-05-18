/**
 * User data structure for the web part of Userman
 */
module userman.web.user;

import userman.id;
import userman.web.group;
import vibe.data.json;
import std.datetime;

struct User {
	alias .ID!User ID;
	@(.name("_id")) ID id;

	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	Group.ID[] groups;
	string activationCode;
	string resetCode;
	SysTime resetCodeExpireTime;
	AuthInfo auth;
	Json[string] properties;

	bool isInGroup(Group.ID group) const
	{
		import std.algorithm : canFind;
		return groups.canFind(group);
	}
}

struct AuthInfo {
	string method = "password";
	string passwordHash;
	string token;
	string secret;
	string info;
}
