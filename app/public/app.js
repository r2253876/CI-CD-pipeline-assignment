const taskForm = document.getElementById('task-form');
const taskInput = document.getElementById('task-input');
const taskList = document.getElementById('task-list');
const emptyState = document.getElementById('empty-state');
const errorState = document.getElementById('error-state');

function showError(message) {
  errorState.textContent = message;
  errorState.hidden = false;
}

function clearError() {
  errorState.hidden = true;
  errorState.textContent = '';
}

async function loadStatus() {
  try {
    const res = await fetch('/api');
    if (!res.ok) throw new Error('status fetch failed');
    const data = await res.json();

    const envPill = document.getElementById('pill-env');
    envPill.textContent = `env: ${data.env}`;
    envPill.className = `pill pill-env-${data.env}`;

    document.getElementById('pill-version').textContent = `version: ${data.version}`;

    const flagPill = document.getElementById('pill-flag');
    flagPill.textContent = `beta: ${data.featureFlagBeta ? 'on' : 'off'}`;
    flagPill.className = `pill ${data.featureFlagBeta ? 'pill-on' : 'pill-off'}`;

    const secretPill = document.getElementById('pill-secret');
    secretPill.textContent = `secret: ${data.secretConfigured ? 'configured' : 'not set'}`;
    secretPill.className = `pill ${data.secretConfigured ? 'pill-on' : 'pill-off'}`;
  } catch (err) {
    // Non-fatal — the task board itself still works even if this call fails.
    console.error('Failed to load /api status', err);
  }
}

function renderTasks(tasks) {
  taskList.innerHTML = '';
  emptyState.hidden = tasks.length !== 0;

  for (const task of tasks) {
    const li = document.createElement('li');
    li.className = `task-item${task.done ? ' done' : ''}`;
    li.dataset.id = task.id;

    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = task.done;
    checkbox.addEventListener('change', () => toggleTask(task.id, checkbox.checked));

    const title = document.createElement('span');
    title.className = 'task-title';
    title.textContent = task.title;

    const del = document.createElement('button');
    del.className = 'task-delete';
    del.type = 'button';
    del.textContent = 'Delete';
    del.addEventListener('click', () => deleteTask(task.id));

    li.append(checkbox, title, del);
    taskList.appendChild(li);
  }
}

async function loadTasks() {
  try {
    const res = await fetch('/api/tasks');
    if (!res.ok) throw new Error('failed to load tasks');
    const data = await res.json();
    clearError();
    renderTasks(data.tasks);
  } catch (err) {
    showError('Could not load tasks — the API may be starting up. Try refreshing in a moment.');
  }
}

async function addTask(title) {
  try {
    const res = await fetch('/api/tasks', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title }),
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || 'failed to add task');
    }
    clearError();
    await loadTasks();
  } catch (err) {
    showError(err.message);
  }
}

async function toggleTask(id, done) {
  try {
    const res = await fetch(`/api/tasks/${id}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ done }),
    });
    if (!res.ok) throw new Error('failed to update task');
    clearError();
    await loadTasks();
  } catch (err) {
    showError(err.message);
  }
}

async function deleteTask(id) {
  try {
    const res = await fetch(`/api/tasks/${id}`, { method: 'DELETE' });
    if (!res.ok && res.status !== 204) throw new Error('failed to delete task');
    clearError();
    await loadTasks();
  } catch (err) {
    showError(err.message);
  }
}

taskForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const title = taskInput.value.trim();
  if (!title) return;
  taskInput.value = '';
  addTask(title);
});

loadStatus();
loadTasks();
