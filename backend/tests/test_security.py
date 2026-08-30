from app.auth.security import create_token, decode_token, hash_password, verify_password


def test_password_hash_is_not_plaintext_and_verifies():
    password = "CorrectHorse123"
    hashed = hash_password(password)
    assert hashed != password
    assert verify_password(password, hashed)
    assert not verify_password("wrong-password", hashed)


def test_jwt_round_trip_contains_subject_and_type():
    token, _ = create_token("user-1", "access", 5, {"role": "PATIENT"})
    payload = decode_token(token)
    assert payload["sub"] == "user-1"
    assert payload["type"] == "access"
    assert payload["role"] == "PATIENT"

