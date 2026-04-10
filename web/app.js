const leafForm = document.getElementById('leaf-form');
const output = document.getElementById('job-output');
const pollButton = document.getElementById('poll-job');
const downloadTemplateButton = document.getElementById('download-template');
const submitBatchButton = document.getElementById('submit-batch');
const batchDownload = document.getElementById('batch-download');

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

function parseBatchCsv(text) {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  if (lines.length < 2) {
    throw new Error('The CSV file is empty. Add at least one row.');
  }

  const expectedHeader = 'profile,common_name,p12_password,san_dns,san_ips';
  if (lines[0].toLowerCase() !== expectedHeader) {
    throw new Error(`Invalid CSV header. Expected: ${expectedHeader}`);
  }

  return lines.slice(1).map((line, index) => {
    const parts = line.split(',');
    if (parts.length < 5) {
      throw new Error(`Invalid row ${index + 2}: expected 5 columns.`);
    }
    return {
      profile: parts[0].trim(),
      common_name: parts[1].trim(),
      p12_password: parts[2],
      san_dns: parts[3]
        .split(';')
        .map((v) => v.trim())
        .filter(Boolean),
      san_ips: parts[4]
        .split(';')
        .map((v) => v.trim())
        .filter(Boolean),
    };
  });
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

downloadTemplateButton.addEventListener('click', async () => {
  const baseUrl = document.getElementById('api-url').value.trim();
  const response = await fetch(`${baseUrl}/templates/leaf-batch.csv`);
  const content = await response.text();
  const blob = new Blob([content], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = 'leaf-batch-template.csv';
  link.click();
  URL.revokeObjectURL(url);
});

submitBatchButton.addEventListener('click', async () => {
  const fileInput = document.getElementById('batch-file');
  const file = fileInput.files[0];
  if (!file) {
    output.textContent = 'Choose a CSV file first.';
    return;
  }

  const baseUrl = document.getElementById('api-url').value.trim();
  const csvText = await file.text();

  let items;
  try {
    items = parseBatchCsv(csvText);
  } catch (error) {
    output.textContent = error.message;
    return;
  }

  const response = await fetch(`${baseUrl}/batch/create-leaf-p12`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ items }),
  });

  const result = await response.json();
  output.textContent = JSON.stringify(result, null, 2);
  batchDownload.textContent = '';

  if (result.download_url) {
    const link = document.createElement('a');
    link.href = `${baseUrl}${result.download_url}`;
    link.textContent = `Download batch ZIP (${result.filename})`;
    batchDownload.appendChild(link);
  }
});
