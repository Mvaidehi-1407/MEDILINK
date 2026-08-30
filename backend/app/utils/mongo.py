from datetime import datetime

from bson import ObjectId


def object_id(value: str) -> ObjectId:
    if not ObjectId.is_valid(value):
        raise ValueError("Invalid object id")
    return ObjectId(value)


def serialize_doc(doc):
    if doc is None:
        return None
    if isinstance(doc, ObjectId):
        return str(doc)
    if isinstance(doc, datetime):
        return doc
    if isinstance(doc, list):
        return [serialize_doc(item) for item in doc]
    if isinstance(doc, dict):
        encoded = {key: serialize_doc(value) for key, value in doc.items()}
        if "_id" in encoded:
            encoded["id"] = str(encoded.pop("_id"))
        return encoded
    return doc
