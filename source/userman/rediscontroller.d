/**
	Database abstraction layer

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.rediscontroller;

import userman.controller;

import vibe.db.redis.redis;

import std.datetime;
import std.exception;
import std.string;
import std.conv;


class RedisController : UserManController {
	private {
		RedisClient m_redis;
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

		m_redis = new RedisClient(url.host, url.port == ushort.init ? 6379 : url.port);
		m_redis.select(dbIndex);
	}

	override bool isEmailRegistered(string email)
	{
		string userId = m_redis.get!string("userman:email_user:" ~ email);
		if (userId != string.init){
			string method = m_redis.hget!string(format("userman:user:%s:auth"), "method");
			return method != string.init && method.length > 0;
		}
		return false;
	}
	
	override void addUser(User usr)
	{
		validateUser(usr);

		enforce(m_redis.get!string("userman:name_user:" ~ usr.name) == string.init, "The user name is already taken.");
		enforce(m_redis.get!string("userman:email_user:" ~ usr.email) == string.init, "The email address is already in use.");

		long userId = m_redis.incr("userman:nextUserId");
		usr.id = to!string(userId);

		// Indexes
		m_redis.zadd("userman:users", userId, userId);
		if (usr.email != string.init) m_redis.set("userman:email_user:" ~ usr.email, to!string(userId));
		if (usr.name != string.init) m_redis.set("userman:name_user:" ~ usr.name, to!string(userId));

		// User
		m_redis.hmset(format("userman:user:%s", userId), 
						"active", to!string(usr.active), 
						"banned", to!string(usr.banned), 
						"name", usr.name, 
						"fullName", usr.fullName, 
						"email", usr.email, 
						"activationCode", usr.activationCode,
						"resetCode", usr.resetCode,
						"resetCodeExpireTime", usr.resetCodeExpireTime == SysTime() ? "" : usr.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_redis.hmset(format("userman:user:%s:auth", userId),
						"method", usr.auth.method,
						"passwordHash", usr.auth.passwordHash,
						"token", usr.auth.token,
						"secret", usr.auth.secret,
						"info", usr.auth.info);

		foreach(string group; usr.groups)
			m_redis.sadd("userman:group:" ~ group ~ ":members", userId);
	}

	override User getUser(string id)
	{
		RedisReply userHash = m_redis.hgetAll("userman:user:" ~ id);
		enforce(userHash.hasNext(), "The specified user id is invalid.");

		auto ret = new User;

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

		RedisReply authHash = m_redis.hgetAll(format("userman:user:%s:auth", id));
		if(authHash.hasNext()) {
			AuthInfo auth;
			while (authHash.hasNext()) {
		 		string key = authHash.next!string();
		 		string value = authHash.next!string();
				switch (key)
				{
					case "method": auth.method = value; break;
					case "passwordHash": auth.passwordHash = value; break;
					case "token": auth.token = value; break;
					case "secret": auth.secret = value; break;
					case "info": auth.info = value; break;
		 			default: break;
				}
			}
			ret.auth = auth;
		}

		RedisReply groupNames = m_redis.zrange("userman:groups", 0, -1);
		while (groupNames.hasNext()) {
			string name = groupNames.next!string();
			if (m_redis.sisMember("userman:group:" ~ name ~ ":members", id))
			{
				++ret.groups.length;
				ret.groups[ret.groups.length - 1] = name;
			}
		}

		return ret;
	}

	override User getUserByName(string name)
	{
		name = name.toLower();

		string userId = m_redis.get!string("userman:name_user:" ~ name);
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

		string userId = m_redis.get!string("userman:email_user:" ~ email);
		try {
			return getUser(userId);
		}
		catch (Exception e) {
			throw new Exception("There is no user account for the specified email address.");
		}
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		string userId = m_redis.get!string("userman:email_user:" ~ email_or_name.toLower());
		if (userId == null) 
			userId = m_redis.get!string("userman:name_user:" ~ email_or_name);

		try {
			return getUser(userId);
		}
		catch (Exception e) {
			throw new Exception("The specified email address or user name is not registered.");
		}
	}

	override void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		RedisReply userIds = m_redis.zrange("userman:users", first_user, first_user + max_count);
		while (userIds.hasNext()) {
			auto usr = getUser(userIds.next!string());
			del(usr);
		}
	}

	override long getUserCount()
	{
		return m_redis.Zcard("userman:users");
	}

	override void deleteUser(string user_id)
	{
		User usr = getUser(user_id);

		if (usr !is null)
		{
			// Indexes
			m_redis.zrem("userman:users", user_id);
			m_redis.del("userman:email_user:" ~ usr.email);
			m_redis.del("userman:name_user:" ~ usr.name);

			// User
			m_redis.del(format("userman:user:%s", user_id));

			// Credentials
			m_redis.del(format("userman:user:%s:auth", user_id));

			// Group membership
			foreach(string group; usr.groups)
				m_redis.srem("userman:group:" ~ group ~ ":members", user_id);
		}
	}

	override void updateUser(User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		// User
		m_redis.hmset(format("userman:user:%s", user.id), 
						"active", to!string(user.active), 
						"banned", to!string(user.banned), 
						"name", user.name, 
						"fullName", user.fullName, 
						"email", user.email, 
						"activationCode", user.activationCode,
						"resetCode", user.resetCode,
						"resetCodeExpireTime", user.resetCodeExpireTime == SysTime() ? "" : user.resetCodeExpireTime.toISOExtString());

		// Credentials
		m_redis.hmset(format("userman:user:%s:auth", user.id),
						"method", user.auth.method,
						"passwordHash", user.auth.passwordHash,
						"token", user.auth.token,
						"secret", user.auth.secret,
						"info", user.auth.info);


		RedisReply groupNames = m_redis.zrange("userman:groups", 0, -1);
		while (groupNames.hasNext()) {
			string name = groupNames.next!string();
			if (user.isInGroup(name))
				m_redis.sadd("userman:group:" ~ name ~ ":members", user.id);
			else
				m_redis.srem("userman:group:" ~ name ~ ":members", user.id);
		}
	}
	
	override void addGroup(string name, string description)
	{
		enforce(!m_redis.hexists("userman:groups", name), "A group with this name already exists.");

		long groupId = m_redis.incr("userman:nextGroupId");

		// Index
		m_redis.zadd("userman:groups", groupId, name);

		// Group
		m_redis.hmset(format("userman:group:%s", groupId),
						"name", name,
						"description", description);

	}
}
