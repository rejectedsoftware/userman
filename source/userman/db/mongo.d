/**
	Database abstraction layer

	Copyright: © 2012-2018 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.db.mongo;

import userman.db.controller;

import vibe.core.log : logDiagnostic;
import vibe.db.mongo.mongo;

import std.exception : enforce;
import std.string;
import std.typecons : tuple;


class MongoUserManController : UserManController {
	private {
		MongoCollection m_users;
		MongoCollection m_groups;
	}

	this(UserManSettings settings)
	{
		super(settings);

		string database = "admin";
		MongoClientSettings dbSettings;
		if (parseMongoDBUrl(dbSettings, settings.databaseURL))
			database = dbSettings.database;

		auto db = connectMongoDB(settings.databaseURL).getDatabase(database);
		m_users = db["userman.users"];
		m_groups = db["userman.groups"];

		// migrate old _id+name format to id (0.3.x -> 0.4.x)
		foreach (usr; m_users.find(["groups": ["$type": cast(int)Bson.Type.objectID]])) {
			logDiagnostic("Migrating user %s from 0.3.x to 0.4.x.", usr["_id"]);
			string[] grps;
			foreach (gid; usr["groups"]) {
				auto g = m_groups.findOne(["_id": gid], ["name": true, "id": true]);
				if (!g.isNull) {
					auto gname = g.tryIndex("name");
					if (gname.isNull) gname = g["id"];
					grps ~= gname.get.get!string;
				}
			}
			m_users.update(["_id": usr["_id"]], ["$set": ["groups": grps]]);
		}
		foreach (grp; m_groups.find(["name": ["$exists": true]])) {
			logDiagnostic("Migrating group %s from 0.3.x to 0.4.x.", grp["name"].get!string);
			auto n = grp["name"];
			grp.remove("name");
			grp["id"] = n;
			m_groups.update(["_id": grp["_id"]], grp);
		}

		IndexOptions opts;
		opts.unique = true;
		m_users.createIndex(IndexModel().add("name", 1).withOptions(opts));
		m_users.createIndex(IndexModel().add("email", 1).withOptions(opts));
	}

	override bool isEmailRegistered(string email)
	{
		auto bu = m_users.findOne(["email": email], ["auth": true]);
		return !bu.isNull() && bu["auth"]["method"].get!string.length > 0;
	}

	override User.ID addUser(ref User usr)
	{
		validateUser(usr);
		enforce(m_users.findOne(["name": usr.name]).isNull(), "The user name is already taken.");
		enforce(m_users.findOne(["email": usr.email]).isNull(), "The email address is already in use.");

		usr.id = User.ID(BsonObjectID.generate());
		m_users.insert(usr);

		return usr.id;
	}

	override User getUser(User.ID id)
	{
		auto usr = m_users.findOne!User(["_id": id.bsonObjectIDValue]);
		enforce(!usr.isNull(), "The specified user id is invalid.");
		return usr.get;
	}

	override User getUserByName(string name)
	{
		name = name.toLower();
		auto usr = m_users.findOne!User(["name": name]);
		enforce(!usr.isNull(), "The specified user name is not registered.");
		return usr.get;
	}

	override User getUserByEmail(string email)
	{
		email = email.toLower();
		auto usr = m_users.findOne!User(["email": email]);
		enforce(!usr.isNull(), "There is no user account for the specified email address.");
		return usr.get;
	}

	override User getUserByEmailOrName(string email_or_name)
	{
		email_or_name = email_or_name.toLower();
		auto usr = m_users.findOne!User(["$or": [["email": email_or_name], ["name": email_or_name]]]);
		enforce(!usr.isNull(), "The specified email address or user name is not registered.");
		return usr.get;
	}

	alias enumerateUsers = UserManController.enumerateUsers;
	override void enumerateUsers(long first_user, long max_count, scope void delegate(ref User usr) @safe del)
	{
		import std.conv : to;
		foreach (usr; m_users.find!User(["query": null, "orderby": ["name": 1]], null, QueryFlags.None, first_user.to!int, max_count.to!int)) {
			if (max_count-- <= 0) break;
			del(usr);
		}
	}

	override long getUserCount()
	{
		return m_users.count(Bson.emptyObject);
	}

	override void deleteUser(User.ID user_id)
	{
		m_users.remove(["_id": user_id.bsonObjectIDValue]);
	}

	override void updateUser(const ref User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");
		// FIXME: enforce that no user names or emails are used twice!

		m_users.update(["_id": user.id.bsonObjectIDValue], user);
	}

	override void setEmail(User.ID user, string email)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["email": email]]);
	}

	override void setFullName(User.ID user, string full_name)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["fullName": full_name]]);
	}

	override void setPassword(User.ID user, string password)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set":
			["auth.method": "password", "auth.passwordHash": generatePasswordHash(password)]]);
	}

	override void setProperty(User.ID user, string name, Json value)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$set": ["properties."~name: value]]);
	}

	override void removeProperty(User.ID user, string name)
	{
		m_users.update(["_id": user.bsonObjectIDValue], ["$unset": ["properties."~name: ""]]);
	}

	override void addGroup(string id, string description)
	{
		enforce(isValidGroupID(id), "Invalid group ID.");
		enforce(m_groups.findOne(["id": id]).isNull(), "A group with this name already exists.");
		auto grp = new Group;
		grp.id = id;
		grp.description = description;
		m_groups.insert(grp);
	}

	override void removeGroup(string id)
	{
		m_groups.remove(["id": id]);
	}

	override void setGroupDescription(string name, string description)
	{
		m_groups.update(["id": name], ["$set": ["description": description]]);
	}

	override long getGroupCount()
	{
		import vibe.data.bson : Bson;
		return m_groups.count(Bson.emptyObject);
	}

	override Group getGroup(string name)
	{
		auto grp = m_groups.findOne!Group(["name": name]);
		enforce(!grp.isNull(), "The specified group name is unknown.");
		return grp.get;
	}

	alias enumerateGroups = UserManController.enumerateGroups;
	override void enumerateGroups(long first_group, long max_count, scope void delegate(ref Group grp) @safe del)
	{
		import std.conv : to;
		foreach (grp; m_groups.find!Group(["query": null, "orderby": ["id": 1]], null, QueryFlags.None, first_group.to!int, max_count.to!int)) {
			if (max_count-- <= 0) break;
			del(grp);
		}
	}

	override void addGroupMember(string group, User.ID user)
	{
		assert(false);
	}

	override void removeGroupMember(string group, User.ID user)
	{
		assert(false);
	}

	override long getGroupMemberCount(string group)
	{
		assert(false);
	}

	alias enumerateGroupMembers = UserManController.enumerateGroupMembers;
	override void enumerateGroupMembers(string group, long first_member, long max_count, scope void delegate(User.ID usr) @safe del)
	{
		assert(false);
	}
}
