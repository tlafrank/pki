from fastapi.testclient import TestClient

from api.app.main import app


client = TestClient(app)


def test_health() -> None:
    response = client.get('/health')
    assert response.status_code == 200
    assert response.json() == {'status': 'ok'}


def test_create_leaf_server_requires_san() -> None:
    payload = {
        'profile': 'server',
        'common_name': 'api.example.internal',
        'p12_password': 'top-secret',
    }
    response = client.post('/jobs/create-leaf-p12', json=payload)
    assert response.status_code == 400
