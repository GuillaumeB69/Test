const storageKeys = {
  theme: "tf_theme",
  profile: "tf_profile",
  members: "tf_members",
  tasks: "tf_tasks",
};

const defaultTasks = [
  { id: crypto.randomUUID(), title: "Préparer la roadmap Q2", status: "todo", priority: "high", dueDate: plusDays(1), comments: [] },
  { id: crypto.randomUUID(), title: "Refonte onboarding mobile", status: "doing", priority: "medium", dueDate: plusDays(4), comments: ["Wireframes validés"] },
  { id: crypto.randomUUID(), title: "Audit sécurité API", status: "done", priority: "high", dueDate: plusDays(-1), comments: ["Rapport partagé"] },
];

let state = {
  profile: load(storageKeys.profile, { name: "Utilisateur", email: "user@example.com" }),
  members: load(storageKeys.members, ["Alice", "Karim", "Jade"]),
  tasks: load(storageKeys.tasks, defaultTasks),
  commentTaskId: null,
};

const dom = {
  themeToggle: q("#themeToggle"),
  profileForm: q("#profileForm"),
  profileName: q("#profileName"),
  profileEmail: q("#profileEmail"),
  memberForm: q("#memberForm"),
  memberName: q("#memberName"),
  teamList: q("#teamList"),
  taskForm: q("#taskForm"),
  taskTitle: q("#taskTitle"),
  taskPriority: q("#taskPriority"),
  taskDueDate: q("#taskDueDate"),
  taskSearch: q("#taskSearch"),
  statusFilter: q("#statusFilter"),
  priorityFilter: q("#priorityFilter"),
  overdueOnly: q("#overdueOnly"),
  todoColumn: q("#todoColumn"),
  doingColumn: q("#doingColumn"),
  doneColumn: q("#doneColumn"),
  kpiGrid: q("#kpiGrid"),
  progressBar: q("#progressBar"),
  progressLabel: q("#progressLabel"),
  deadlineAlerts: q("#deadlineAlerts"),
  activityFeed: q("#activityFeed"),
  commentsDialog: q("#commentsDialog"),
  commentTaskTitle: q("#commentTaskTitle"),
  commentList: q("#commentList"),
  commentInput: q("#commentInput"),
  addCommentBtn: q("#addCommentBtn"),
  toast: q("#toast"),
  newTaskShortcut: q("#newTaskShortcut"),
};

init();

function init() {
  applyTheme(load(storageKeys.theme, "light"));
  bindEvents();
  render();
}

function bindEvents() {
  dom.themeToggle.addEventListener("click", () => {
    const nextTheme = document.body.dataset.theme === "dark" ? "light" : "dark";
    applyTheme(nextTheme);
    save(storageKeys.theme, nextTheme);
    notify(`Thème ${nextTheme} activé`);
  });

  dom.profileForm.addEventListener("submit", (e) => {
    e.preventDefault();
    state.profile = { name: dom.profileName.value.trim(), email: dom.profileEmail.value.trim() };
    save(storageKeys.profile, state.profile);
    pushActivity(`Profil mis à jour par ${state.profile.name}`);
    notify("Profil enregistré");
  });

  dom.memberForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const name = dom.memberName.value.trim();
    if (!name) return;
    state.members.unshift(name);
    save(storageKeys.members, state.members);
    dom.memberName.value = "";
    renderTeam();
    notify(`Membre ajouté: ${name}`);
  });

  dom.taskForm.addEventListener("submit", (e) => {
    e.preventDefault();
    const title = dom.taskTitle.value.trim();
    if (!title) return;
    state.tasks.unshift({
      id: crypto.randomUUID(),
      title,
      status: "todo",
      priority: dom.taskPriority.value,
      dueDate: dom.taskDueDate.value,
      comments: [],
    });
    save(storageKeys.tasks, state.tasks);
    dom.taskForm.reset();
    renderTasks();
    renderDashboard();
    notify("Tâche créée");
  });

  [dom.taskSearch, dom.statusFilter, dom.priorityFilter, dom.overdueOnly].forEach((el) => {
    el.addEventListener("input", renderTasks);
    el.addEventListener("change", renderTasks);
  });

  [dom.todoColumn, dom.doingColumn, dom.doneColumn].forEach((column) => {
    column.addEventListener("dragover", (e) => e.preventDefault());
    column.addEventListener("drop", (e) => {
      const id = e.dataTransfer.getData("text/plain");
      const status = column.id.replace("Column", "");
      updateTask(id, { status });
      pushActivity(`Statut modifié: ${findTask(id)?.title ?? "Tâche"} → ${labelStatus(status)}`);
      notify("Tâche déplacée");
    });
  });

  dom.addCommentBtn.addEventListener("click", (e) => {
    e.preventDefault();
    const text = dom.commentInput.value.trim();
    if (!text || !state.commentTaskId) return;
    const task = findTask(state.commentTaskId);
    task.comments.push(text);
    save(storageKeys.tasks, state.tasks);
    dom.commentInput.value = "";
    renderComments();
    notify("Commentaire ajouté");
  });

  dom.newTaskShortcut.addEventListener("click", () => dom.taskTitle.focus());

  document.addEventListener("keydown", (e) => {
    if (e.key === "/") {
      e.preventDefault();
      dom.taskSearch.focus();
    }
    if (e.key.toLowerCase() === "n" && !isTyping(e.target)) {
      e.preventDefault();
      dom.taskTitle.focus();
    }
    if (e.key.toLowerCase() === "t" && !isTyping(e.target)) {
      e.preventDefault();
      dom.themeToggle.click();
    }
  });
}

function render() {
  dom.profileName.value = state.profile.name;
  dom.profileEmail.value = state.profile.email;
  renderTeam();
  renderTasks();
  renderDashboard();
}

function renderTeam() {
  dom.teamList.innerHTML = "";
  state.members.forEach((member, i) => {
    const li = document.createElement("li");
    li.innerHTML = `<span>${member}</span><button class="btn ghost" data-remove-member="${i}">Retirer</button>`;
    li.querySelector("button").onclick = () => {
      state.members.splice(i, 1);
      save(storageKeys.members, state.members);
      renderTeam();
      notify("Membre retiré");
    };
    dom.teamList.appendChild(li);
  });
}

function renderTasks() {
  const filters = {
    search: dom.taskSearch.value.toLowerCase().trim(),
    status: dom.statusFilter.value,
    priority: dom.priorityFilter.value,
    overdueOnly: dom.overdueOnly.checked,
  };

  [dom.todoColumn, dom.doingColumn, dom.doneColumn].forEach((col) => (col.innerHTML = ""));

  state.tasks
    .filter((t) => t.title.toLowerCase().includes(filters.search))
    .filter((t) => (filters.status === "all" ? true : t.status === filters.status))
    .filter((t) => (filters.priority === "all" ? true : t.priority === filters.priority))
    .filter((t) => (filters.overdueOnly ? isOverdue(t) : true))
    .forEach((task) => {
      const card = document.createElement("article");
      card.className = "task-card";
      card.draggable = true;
      card.ondragstart = (e) => e.dataTransfer.setData("text/plain", task.id);

      card.innerHTML = `
        <div class="task-head">
          <strong>${task.title}</strong>
          <span class="badge ${task.priority}">${task.priority}</span>
        </div>
        <div class="task-meta">Échéance: ${task.dueDate || "-"} ${isOverdue(task) ? "⚠️" : ""}</div>
        <div class="task-meta">Commentaires: ${task.comments.length}</div>
        <div class="task-actions">
          <button class="btn ghost" data-comment="${task.id}">Commenter</button>
        </div>
      `;

      card.querySelector("[data-comment]").onclick = () => openComments(task.id);
      q(`#${task.status}Column`).appendChild(card);
    });
}

function renderDashboard() {
  const total = state.tasks.length || 1;
  const done = state.tasks.filter((t) => t.status === "done").length;
  const doing = state.tasks.filter((t) => t.status === "doing").length;
  const overdue = state.tasks.filter(isOverdue).length;
  const completion = Math.round((done / total) * 100);

  dom.kpiGrid.innerHTML = "";
  [
    { label: "Total tâches", value: state.tasks.length },
    { label: "En cours", value: doing },
    { label: "En retard", value: overdue },
  ].forEach((kpi) => {
    const el = document.createElement("div");
    el.className = "kpi";
    el.innerHTML = `<small>${kpi.label}</small><b>${kpi.value}</b>`;
    dom.kpiGrid.appendChild(el);
  });

  dom.progressBar.style.width = `${completion}%`;
  dom.progressLabel.textContent = `${completion}% terminé`;

  dom.deadlineAlerts.innerHTML = "";
  state.tasks
    .filter((t) => t.status !== "done")
    .sort((a, b) => a.dueDate.localeCompare(b.dueDate))
    .slice(0, 5)
    .forEach((t) => {
      const li = document.createElement("li");
      li.textContent = `${isOverdue(t) ? "Retard" : "À venir"} · ${t.title} (${t.dueDate})`;
      dom.deadlineAlerts.appendChild(li);
    });

  if (!dom.activityFeed.children.length) {
    ["Bienvenue sur TaskFlow Pro", "Astuce: touche / pour rechercher", "Astuce: touche T pour changer le thème"].forEach(pushActivity);
  }
}

function pushActivity(message) {
  const li = document.createElement("li");
  li.textContent = `${new Date().toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })} · ${message}`;
  dom.activityFeed.prepend(li);
  while (dom.activityFeed.children.length > 8) dom.activityFeed.lastChild.remove();
}

function openComments(taskId) {
  state.commentTaskId = taskId;
  const task = findTask(taskId);
  dom.commentTaskTitle.textContent = `Commentaires · ${task.title}`;
  renderComments();
  dom.commentsDialog.showModal();
}

function renderComments() {
  const task = findTask(state.commentTaskId);
  dom.commentList.innerHTML = "";
  task.comments.forEach((c) => {
    const li = document.createElement("li");
    li.textContent = c;
    dom.commentList.appendChild(li);
  });
  renderTasks();
}

function updateTask(id, updates) {
  const task = findTask(id);
  Object.assign(task, updates);
  save(storageKeys.tasks, state.tasks);
  renderTasks();
  renderDashboard();
}

function applyTheme(theme) {
  document.body.dataset.theme = theme;
  dom.themeToggle.textContent = theme === "dark" ? "☀️" : "🌙";
}

function findTask(id) {
  return state.tasks.find((t) => t.id === id);
}

function isOverdue(task) {
  return task.status !== "done" && task.dueDate && task.dueDate < new Date().toISOString().slice(0, 10);
}

function labelStatus(status) {
  return { todo: "À faire", doing: "En cours", done: "Terminé" }[status] ?? status;
}

function notify(msg) {
  dom.toast.textContent = msg;
  dom.toast.classList.add("show");
  setTimeout(() => dom.toast.classList.remove("show"), 1800);
}

function load(key, fallback) {
  const raw = localStorage.getItem(key);
  return raw ? JSON.parse(raw) : fallback;
}

function save(key, value) {
  localStorage.setItem(key, JSON.stringify(value));
}

function q(sel) {
  return document.querySelector(sel);
}

function plusDays(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toISOString().slice(0, 10);
}

function isTyping(target) {
  return ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName);
}
