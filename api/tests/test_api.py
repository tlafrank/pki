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


def test_leaf_batch_template_download() -> None:
    response = client.get('/templates/leaf-batch.csv')
    assert response.status_code == 200
    assert 'profile,common_name,p12_password,san_dns,san_ips' in response.text


def test_batch_create_leaf_server_requires_san() -> None:
    payload = {
        'items': [
            {
                'profile': 'server',
                'common_name': 'api.example.internal',
                'p12_password': 'top-secret',
                'san_dns': [],
                'san_ips': [],
            }
        ]
    }
    response = client.post('/batch/create-leaf-p12', json=payload)
    assert response.status_code == 400
