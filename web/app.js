const leafForm = document.getElementById('leaf-form');
const output = document.getElementById('job-output');
const pollButton = document.getElementById('poll-job');

function parseCsv(value) {
  return value
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

async function fetchJob(baseUrl, jobId) {
  const response = await fetch(`${baseUrl}/jobs/${jobId}`);
  const payload = await response.json();
  output.textContent = JSON.stringify(payload, null, 2);
}

leafForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const baseUrl = document.getElementById('api-url').value.trim();

  const payload = {
    profile: document.getElementById('profile').value,
    common_name: document.getElementById('common-name').value.trim(),
    p12_password: document.getElementById('p12-password').value,
    san_dns: parseCsv(document.getElementById('san-dns').value),
    san_ips: parseCsv(document.getElementById('san-ips').value),
  };

  const response = await fetch(`${baseUrl}/jobs/create-leaf-p12`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });

  const result = await response.json();
  output.textContent = JSON.stringify(result, null, 2);

  if (result.id) {
    document.getElementById('job-id').value = result.id;
  }
});

pollButton.addEventListener('click', async () => {
  const baseUrl = document.getElementById('api-url').value.trim();
  const jobId = document.getElementById('job-id').value.trim();
  if (!jobId) {
    output.textContent = 'Enter a job ID first.';
    return;
  }
  await fetchJob(baseUrl, jobId);
});
