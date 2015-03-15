/**
	Generic typesafe ID type to abstract away the underlying database.

	Copyright: © 2014-2015 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.id;

import vibe.data.bson;
import std.uuid;

struct ID(KIND)
{
	import std.conv;

	alias Kind = KIND;

	private {
		union {
			long m_long;
			BsonObjectID m_bsonObjectID;
			UUID m_uuid;
		}
		IDType m_type;
	}

	alias toString this;

	this(long id) { this = id; }
	this(BsonObjectID id) { this = id; }
	this(UUID id) { this = id; }

	@property BsonObjectID bsonObjectIDValue() const { assert(m_type == IDType.bsonObjectID); return m_bsonObjectID; }
	@property long longValue() const { assert(m_type == IDType.long_); return m_long; }
	@property UUID uuidValue() const { assert(m_type == IDType.uuid); return m_uuid; }

	void opAssign(long id) { m_type = IDType.long_; m_long = id; }
	void opAssign(BsonObjectID id) { m_type = IDType.bsonObjectID; m_bsonObjectID = id; }
	void opAssign(UUID id) { m_type = IDType.uuid; m_uuid = id; }
	void opAssign(ID id)
	{
		final switch (id.m_type) {
			case IDType.long_: this = id.m_long; break;
			case IDType.bsonObjectID: this = id.m_bsonObjectID; break;
			case IDType.uuid: this = id.m_uuid; break;
		}
	}

	static ID fromBson(Bson id) { return ID(id.get!BsonObjectID); }
	Bson toBson() const { assert(m_type == IDType.bsonObjectID); return Bson(m_bsonObjectID); }

	static ID fromLong(long id) { return ID(id); }
	long toLong() const { assert(m_type == IDType.long_); return m_long; }

	static ID fromString(string str)
	{
		if (str.length == 24) return ID(BsonObjectID.fromString(str));
		else if (str.length == 36) return ID(UUID(str));
		else return ID(str.to!long);
	}

	string toString()
	const {
		final switch (m_type) {
			case IDType.long_: return m_long.to!string;
			case IDType.bsonObjectID: return m_bsonObjectID.toString();
			case IDType.uuid: return m_uuid.toString();
		}
	}
}

static assert(isBsonSerializable!(ID!void));
unittest {
	assert(serializeToBson(ID!void(BsonObjectID.init)).type == Bson.Type.objectID);
}

enum IDType {
	long_,
	bsonObjectID,
	uuid
}
