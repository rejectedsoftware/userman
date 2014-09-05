/**
	Database abstraction layer

	Copyright: © 2012-2014 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: David Suppiger
*/
module userman.rediscontroller;

import userman.controller;

import vibe.db.redis.redis;
import vibe.db.redis.idioms;

import std.datetime;
import std.exception;
import std.string;
import std.conv;


class RedisUserManController : UserManController {
	private {
		RedisClient m_redisClient;
		RedisDatabase m_redisDB;

		RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none) m_authInfos;
		RedisObjectCollection!(Group, RedisCollectionOptions.supportPaging) m_groups;
	}
	
	this(UserManSettings settings)
	{	
		super(settings);

		string schema = "redis";
		auto idx = settings.databaseURL.indexOf("://");
		if (idx > 0)
			schema = settings.databaseURL[0..idx];

		enforce(schema == "redis", "databaseURL must be a redis connection string");

		// Parse string by replacing schema with 'http' as URL won't parse redis
		// URLs correctly.
		string url_string = settings.databaseURL;
		if (idx > 0) 
			url_string = url_string[idx+3..$];

		URL url = URL("http://" ~ url_string);
		url.schema = "redis";

		long dbIndex = 0;
		if (!url.path.empty)
			dbIndex = to!long(url.path.nodes[0].toString());

		m_redisClient = connectRedis(url.host, url.port == ushort.init ? 6379 : url.port);
		m_redisDB = m_redisClient.getDatabase(dbIndex);

		m_authInfos = RedisObjectCollection!(AuthInfo, RedisCollectionOptions.none)(m_redisDB, "userman:user", "auth");
		m_groups = RedisObjectCollection!(Group, RedisCollectionOptions.supportPaging)(m_redisDB, "userman:group");
	}

	override bool isEmailRegistered(string email)
	{
		long userId = m_redisDB.get!long("userman:email_user:" ~ email);
		if (userId >= 0){
			string method = m_authInfos[userId].method;
			return method != string.init && method.length > 0;
		}
		return false;
	}
	
	override User.ID addUser(ref User usr)
	{
		validateUser(usr);

		enforce(m_redisDB.get!string("userman:name_user:" ~ usr.name) == string.init, "The user name is already taken.");
		enforce(m_redisDB.get!string("userman:email_user:" ~ usr.email) == string.init, "The email address is already in use.");

		long userId = m_redisDB.incr("userman:user:max");
		m_redisDB.zadd("userman:user:all", userId, userId);
		usr.id = User.ID(userId);

		// Indexes
		if (usr.email != string.init) m_redisDB.set("userman:email_user:" ~ usr.email, to!string(userId));
		if (usr.name != string.init) m_redisDB.set("userman:name_user:" ~ usr.name, to!string(userId));

		// User
		m_redisDB.hmset(format("userman:user:%s", userId), 
						"active", to!string(usr.active), 
						"banned", to!string(usr.banned), 
						"name", usr.name, 
						"fullName", usr.fullName, 
						"email", usr.email, 
						"activationCode", usr.activationCode,
						"resetCode", usr.resetCode,
						"resetCodeExpireTime", usr.resetCodeExpireTime == SysTime() ? "" : usr.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_authInfos[userId] = usr.auth;

		foreach(Group.ID gid; usr.groups)
			m_redisDB.sadd("userman:group:" ~ gid ~ ":members", userId);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		auto userHash = m_redisDB.hgetAll("userman:user:" ~ id);
		enforce(userHash.hasNext(), "The specified user id is invalid.");

		User ret;

		ret.id = id;
		while (userHash.hasNext()) {
		 	string key = userHash.next!string();
		 	string value = userHash.next!string();
		 	switch (key)
		 	{
		 		case "active": ret.active = to!bool(value); break;
		 		case "banned": ret.banned = to!bool(value); break;
		 		case "name": ret.name = value; break;
		 		case "fullName": ret.fullName = value; break;
		 		case "email": ret.email = value; break;
		 		case "activationCode": ret.activationCode = value; break;
		 		case "resetCode": ret.resetCode = value; break;
		 		case "resetCodeExpireTime":
		 			try {
		 				ret.resetCodeExpireTime = SysTime.fromISOExtString(value);
	 				} catch (DateTimeException dte) {}
	 				break;
		 		default: break;
		 	}
		}

		ret.auth = m_authInfos[id.longValue];

		foreach (id, grp; m_groups) {
			if (m_redisDB.sisMember("userman:group:" ~ grp.id ~ ":members", id))
			{
				++ret.groups.length;
				ret.groups[ret.groups.length - 1] = grp.id;
			}
		}

		return ret;
	}

	override User getUserByName(string name)
	{
		name = name.toLower();

		User.ID userId = m_redisDB.get!string("userman:name_user:" ~ name).to!long;
		try {
			return getUser(userId);
		}
		catch (Exception e) {
			throw new Exception("The specified user name is not registered.");
		}
	}

	override User getUserByEmail(string email)
	{
		email = email.toLower();

		User.ID userId = m_redisDB.get!string("userman:email_user:" ~ email).to!long;
		try {
			return getUser(userId);
		}
		catch (Exception e) {
			throw new Exception("There is no user account for the specified email address.");
		}
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		string userId = m_redisDB.get!string("userman:email_user:" ~ email_or_name.toLower());
		if (userId == null) 
			userId = m_redisDB.get!string("userman:name_user:" ~ email_or_name);

		try {
			return getUser(User.ID(userId.to!long));
		}
		catch (Exception e) {
			throw new Exception("The specified email address or user name is not registered.");
		}
	}

	override void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		foreach (userId; m_redisDB.zrange!string("userman:user:all", first_user, first_user + max_count)) {
			auto usr = getUser(User.ID(userId.to!long));
			del(usr);
		}
	}

	override long getUserCount()
	{
		return m_redisDB.zcard("userman:user:all");
	}

	override void deleteUser(User.ID user_id)
	{
		User usr = getUser(user_id);

		// Indexes
		m_redisDB.zrem("userman:user:all", user_id);
		m_redisDB.del("userman:email_user:" ~ usr.email);
		m_redisDB.del("userman:name_user:" ~ usr.name);

		// User
		m_redisDB.del(format("userman:user:%s", user_id));

		// Credentials
		m_authInfos.remove(user_id.longValue);

		// Group membership
		foreach(Group.ID gid; usr.groups)
			m_redisDB.srem("userman:group:" ~ gid ~ ":members", user_id);
	}

	override void updateUser(in ref User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		// User
		m_redisDB.hmset(format("userman:user:%s", user.id), 
						"active", to!string(user.active), 
						"banned", to!string(user.banned), 
						"name", user.name, 
						"fullName", user.fullName, 
						"email", user.email, 
						"activationCode", user.activationCode,
						"resetCode", user.resetCode,
						"resetCodeExpireTime", user.resetCodeExpireTime == SysTime() ? "" : user.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_authInfos[user.id.longValue] = user.auth;


		foreach (id, grp; m_groups) {
			if (user.isInGroup(grp.id))
				m_redisDB.sadd("userman:group:" ~ grp.id ~ ":members", user.id);
			else
				m_redisDB.srem("userman:group:" ~ grp.id ~ ":members", user.id);
		}
	}
	
	override void setEmail(User.ID user, string email)
	{
		assert(false);
	}

	override void setFullName(User.ID user, string full_name)
	{
		assert(false);
	}
	
	override void setPassword(User.ID user, string password)
	{
		assert(false);
	}
	
	override void setProperty(User.ID user, string name, string value)
	{
		assert(false);
	}
	
	override void addGroup(string name, string description)
	{
		foreach (id, grp; m_groups) {
			enforce(grp.name != name, "A group with this name already exists.");
		}

		// Add Group
		long groupId = m_groups.createID();
		Group grp = {
			id: Group.ID(groupId), 
			name: name, 
			description: description
		};

		m_groups[groupId] = grp;

	}
}
