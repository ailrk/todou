import { h, createRef, navigate } from "./vdom.js";
import { base64ToBitSet, dateToLocalISOString, fmtYM } from "./lib.js";
function isCompleted(e) { return e.completedDate !== null; }
/*
 * Render
 */
export function renderTodo(model) {
    return (h("div", { class: "todou-container", tabindex: "-1" },
        h("nav", null,
            h("span", { onclick: (_) => { toggleCalendar(model); } },
                " ",
                model.date,
                " "),
            h("div", { class: "control" },
                h("span", { class: "today-icon icon", onclick: (_) => { navigate(`/`); } }),
                h("span", { class: "stat-icon icon", onclick: (_) => { navigate(`/summary?date=${model.date}`); } }))),
        h("section", { class: "todoapp pg-todo" },
            renderInput(model),
            renderEntries(model),
            renderControls(model)),
        renderFooterInfo(),
        model.showCalendar ? renderCalendarModal(model) : null,
        model.showDetail ? renderDetailModal(model) : null));
}
function renderInput(model) {
    return (h("header", null,
        h("input", { class: "new-todo", placeholder: "What needs to be done?", autofocus: true, value: model.field, name: "newTodo", onkeydown: (ev) => {
                if (ev.key === "Enter") {
                    addEntry(model);
                }
            }, oninput: (ev) => {
                updateField(model, ev.target.value);
            } })));
}
function renderEntries(model) {
    const { visibility, entries } = model;
    const allCompleted = entries.reduce((completed, entry) => isCompleted(entry) && completed, false);
    const cssVisibility = entries.length === 0 ? "hidden" : "visible";
    const isVisible = (entry) => {
        switch (visibility) {
            case "Completed": return isCompleted(entry);
            case "Active": return !isCompleted(entry);
            default: return true;
        }
    };
    return (h("section", { class: "main", style: `visibility:${cssVisibility}` },
        h("input", { class: "toggle-all", type: "checkbox", checked: allCompleted, onclick: () => checkAllEntries(model, !allCompleted) }),
        h("label", { for: "toggle-all" }, "Mark all as complete"),
        h("ul", { class: "todo-list" }, entries.filter(isVisible).map(entry => renderEntry(model, entry)))));
}
function renderControls(model) {
    const { visibility, entries } = model;
    const entriesCompleted = entries.filter(isCompleted).length;
    const entriesLeft = entries.length - entriesCompleted;
    return (h("footer", { class: "footer", hidden: entries.length === 0 },
        renderControlsCount(entriesLeft),
        renderControlsFilter(model, visibility)));
}
function renderControlsCount(entriesLeft) {
    return (h("span", { class: "todo-count" },
        h("strong", null, entriesLeft),
        " ",
        entriesLeft === 1 ? " item" : " items"));
}
function renderControlsFilter(model, visibility) {
    return (h("ul", { class: "filters" },
        visibilitySwap(model, "#/", "All", visibility),
        visibilitySwap(model, "#/active", "Active", visibility),
        visibilitySwap(model, "#/completed", "Completed", visibility)));
}
function visibilitySwap(model, uri, vis, currentVis) {
    return (h("li", { onclick: () => changeVisibility(model, vis) },
        h("a", { href: uri, class: vis === currentVis ? "selected" : "" }, vis)));
}
function renderFooterInfo() {
    return (h("footer", { class: "info" },
        h("p", null, "Double click to edit a todo")));
}
function renderEntry(model, entry) {
    const classes = [isCompleted(entry) ? "completed" : ""].filter(Boolean).join(" ");
    return (h("li", { key: `todo-${entry.id}`, class: "entry-description " },
        h("input", { class: "toggle", type: "checkbox", checked: isCompleted(entry), onclick: () => { checkEntry(model, entry.id, !isCompleted(entry)); } }),
        h("label", { class: classes, onclick: () => {
                model.entry = entry;
                toggleDetail(model);
            } }, entry.description),
        h("div", { class: "entry-tags" }, entry.tags.map(tag => renderTag(model, entry, tag, false))),
        h("button", { class: "destroy", onclick: () => deleteEntry(model, entry.id) })));
}
function renderTag(model, entry, tag, canDelete = true) {
    return (h("div", { key: `todo-detail-tag-${tag}`, class: "tag" },
        h("span", null, tag),
        !canDelete ? null :
            h("button", { class: "delete-tag", onclick: () => deleteTag(model, entry, tag) })));
}
function renderTags(model, entry) {
    async function onKeydown(ev) {
        if (ev.key === "Enter") {
            const input = ev.target;
            const newTag = input.value.trim();
            if (newTag) {
                if (entry.tags.includes(newTag)) {
                    input.classList.add('error');
                    setTimeout(() => {
                        input.classList.remove('error');
                    }, 800);
                }
                else {
                    entry.tags.push(newTag);
                    input.value = "";
                    await updateEntryAPI(model.date, entry.id, { tags: entry.tags });
                }
            }
        }
        await model.vdom.render();
    }
    return (h("div", { class: "detail-tags" },
        entry.tags.map(tag => renderTag(model, entry, tag)),
        h("div", { class: "add-tag-container" },
            h("input", { type: "text", placeholder: "+ Tag", onkeydown: onKeydown }))));
}
function renderDetailDescription(model) {
    if (model.entry === null)
        return "No Entry";
    let entry = model.entry;
    let inputRef = createRef();
    const classes = !model.entry ? "" :
        [isCompleted(model.entry) ? "completed" : "",
            model.entry.editingDescription ? "editing" : "non-editing"
        ].filter(Boolean).join(" ");
    function onCheck() {
        checkEntry(model, entry.id, !isCompleted(entry));
    }
    function onClick() {
        editingEntryDescription(model, entry.id, true);
        if (inputRef.current) {
            let el = inputRef.current;
            el.focus();
        }
    }
    function onKeydown(ev) {
        if (ev.key === "Enter" && !ev.shiftKey || ev.key === "Escape") {
            ev.preventDefault();
            editingEntryDescription(model, entry.id, false);
        }
    }
    function onInput(ev) {
        updateEntry(model, entry.id, { description: ev.target.value });
    }
    function onBlur() {
        editingEntryDescription(model, entry.id, false);
    }
    function onDestroy() {
        deleteEntry(model, entry.id);
        toggleDetail(model, false);
    }
    return (h("div", { class: "entry-description edit " + classes },
        h("input", { class: "toggle", type: "checkbox", checked: isCompleted(entry), onclick: onCheck }),
        h("input", { name: "description", value: entry.description, ref: inputRef, id: `todo-description-${entry.id}`, onclick: onClick, onkeydown: onKeydown, oninput: onInput, onblur: onBlur }),
        h("button", { class: "destroy", onclick: onDestroy })));
}
function renderDetail(model) {
    if (model.entry === null)
        return "No Entry";
    let entry = model.entry;
    let textAreaRef = createRef();
    const classes = !model.entry ? "" :
        [model.entry.editingDetail ? "editing" : "non-editing"
        ].filter(Boolean).join(" ");
    function onClick() {
        editingEntryDetail(model, entry.id, true);
    }
    function onKeydown(ev) {
        if (ev.key === "Escape") {
            ev.preventDefault();
            ev.stopPropagation();
            editingEntryDetail(model, entry.id, false);
        }
    }
    function onInput(ev) {
        updateEntry(model, entry.id, { detail: ev.target.value });
        if (textAreaRef.current) {
            let el = textAreaRef.current;
            el.focus();
        }
    }
    function onBlur() {
        editingEntryDetail(model, entry.id, false);
    }
    return (h("div", { class: "entry-detail edit " + classes },
        h("textarea", { name: "detail", value: entry.detail, ref: textAreaRef, id: `todo-detail-${entry.id}`, onclick: onClick, onkeydown: onKeydown, oninput: onInput, onblur: onBlur })));
}
function renderCompletedDate(model) {
    if (model.entry === null) {
        return "Empty Entry";
    }
    let entry = model.entry;
    let inputRef = createRef();
    const isNumeric = (str) => str.length > 0 && [...str].every(c => c >= '0' && c <= '9');
    function isValidDate(d) {
        let ds = d.trim().split("-").filter(s => s !== "");
        if (ds.length !== 3)
            return false;
        if (ds[0].length !== 4 || !isNumeric(ds[0]))
            return false;
        if (ds[1].length !== 2 || !isNumeric(ds[1]))
            return false;
        if (ds[2].length !== 2 || !isNumeric(ds[2]))
            return false;
        if (new Date(d) < new Date(model.date))
            return false;
        return true;
    }
    // Cascade to blur
    async function onKeydown(ev) {
        if (ev.key === "Enter") {
            let input = ev.target;
            input.blur();
        }
    }
    async function onBlur(ev) {
        let input = ev.target;
        let completedDate = input.value.trim();
        if (isValidDate(completedDate)) {
            entry.completedDate = completedDate;
            editingEntryDetail(model, entry.id, false);
        }
        else {
            input.classList.add('error');
            setTimeout(() => {
                input.classList.remove('error');
            }, 800);
        }
    }
    return (model.entry.completedDate !== null
        ?
            h("div", { class: "detail-completed-date-container" },
                h("input", { type: "text", ref: inputRef, placeholder: "completed at", onkeydown: onKeydown, onblur: onBlur, value: model.entry.completedDate }))
        : null);
}
function renderDetailModal(model) {
    if (model.entry === null) {
        return "Empty Entry";
    }
    let contentRef = createRef();
    return (h("div", { class: "detail-modal modal", tabindex: "-1", onkeydown: (ev) => {
            if (["ArrowLeft", "ArrowRight"].includes(ev.key)) {
                ev.stopPropagation();
            }
        }, onclick: (ev) => {
            let path = ev.composedPath();
            if (contentRef.current && path.includes(contentRef.current)) {
                return;
            }
            toggleDetail(model, false);
        } },
        h("div", { class: "detail-content", ref: contentRef },
            h("div", { class: "detail-header" },
                renderDetailDescription(model),
                renderCompletedDate(model),
                renderTags(model, model.entry)),
            h("div", { class: "detail-body" }, renderDetail(model)))));
}
function renderCalendarModal(model) {
    const firstDay = new Date(model.calendar.year, model.calendar.month, 1);
    const lastDay = new Date(model.calendar.year, model.calendar.month + 1, 0);
    const daysInMonth = lastDay.getDate();
    const firstDayOfWeek = firstDay.getDay();
    const formatted = fmtYM(model.calendar);
    const date = new Date(model.date + "T00:00:00");
    function dateEq(i, calendar, d) {
        return calendar.year === d.getFullYear() &&
            calendar.month === d.getMonth() &&
            i === d.getDate();
    }
    function today(i) {
        let now = new Date();
        if (dateEq(i, model.calendar, now))
            return " cal-today";
        else
            return "";
    }
    function current(i) {
        if (dateEq(i, model.calendar, date))
            return " cal-current";
        else
            return "";
    }
    function presence(i) {
        // immediately set current non-mempty todo as presence
        if (dateEq(i, model.calendar, date)) {
            if (model.entries.length > 0) {
                if (model.entries.every(isCompleted)) {
                    return " cal-completed";
                }
                return " cal-presence";
            }
        }
        if (model.firstDay === "")
            return "";
        let v = model.presence.view(i, model.calendar, model.firstDay);
        let result = "";
        if (v.presence) {
            result += " cal-presence";
        }
        if (v.completed) {
            result += " cal-completed";
        }
        return result;
    }
    function jump(i) {
        let url = "";
        url += `/${model.calendar.year}-`;
        url += `${String(model.calendar.month + 1).padStart(2, '0')}-`;
        url += `${String(i).padStart(2, '0')}`;
        navigate(url);
    }
    function renderDay(i) {
        return (h("li", { class: today(i) + " " + current(i) + " " + presence(i), style: i == 1 ? `grid-column-start: ${firstDayOfWeek + 1}` : "", onclick: () => jump(i) }, i));
    }
    function renderDays() {
        return Array.from({ length: daysInMonth }, (_, i) => i + 1).map(renderDay);
    }
    return (h("div", { class: "calendar-modal modal", tabindex: "-1", onkeydown: (ev) => {
            // Prevent the page from scrolling when using arrows
            if (["ArrowLeft", "ArrowRight"].includes(ev.key)) {
                ev.preventDefault();
            }
            ev.stopPropagation();
            switch (ev.key) {
                case "ArrowLeft":
                    prevCalendar(model);
                    break;
                case "ArrowRight":
                    nextCalendar(model);
                    break;
            }
        }, onclick: (ev) => {
            if (document.querySelector('.calendar-content').contains(ev.target))
                return;
            toggleCalendar(model, false);
        } },
        h("div", { class: "calendar-content" },
            h("span", { class: "calendar-header" },
                h("button", { onclick: (_) => { prevCalendar(model); } }),
                h("h1", null, formatted),
                h("button", { onclick: (_) => { nextCalendar(model); } })),
            h("ol", { class: "calendar" },
                h("li", { class: "day-name" }, "Sun"),
                " ",
                h("li", { class: "day-name" }, "Mon"),
                " ",
                h("li", { class: "day-name" }, "Tue"),
                h("li", { class: "day-name" }, "Wed"),
                " ",
                h("li", { class: "day-name" }, "Thu"),
                " ",
                h("li", { class: "day-name" }, "Fri"),
                h("li", { class: "day-name" }, "Sat"),
                renderDays()))));
}
async function addEntry(model) {
    if (model.field === "")
        return;
    let newEntry = {
        id: model.nextId,
        description: model.field,
        detail: "",
        tags: [],
        editingDescription: false,
        editingDetail: false,
        completedDate: null
    };
    await addEntryAPI(model.date, newEntry.id, newEntry.description);
    model.nextId++;
    model.field = "";
    model.entries.push(newEntry);
    await model.vdom.render();
}
async function updateField(model, str) {
    model.field = str;
    await model.vdom.render();
}
async function editingEntryDescription(model, id, isEditing = false) {
    let entry = model.entries.filter(e => e.id === id).at(0);
    if (!entry)
        return;
    entry.editingDescription = isEditing;
    if (!isEditing) {
        await updateEntryAPI(model.date, id, {
            completedDate: entry.completedDate,
            description: entry.description,
            detail: entry.detail,
            tags: entry.tags
        });
    }
    await model.vdom.render();
}
async function editingEntryDetail(model, id, isEditing = false) {
    let entry = model.entries.filter(e => e.id === id).at(0);
    if (!entry)
        return;
    entry.editingDetail = isEditing;
    if (!isEditing) {
        await updateEntryAPI(model.date, id, {
            completedDate: entry.completedDate,
            description: entry.description,
            detail: entry.detail,
            tags: entry.tags
        });
    }
    await model.vdom.render();
}
async function updateEntry(model, id, delta) {
    model.entries.forEach(entry => {
        if (entry.id === id) {
            if (delta.description !== undefined) {
                entry.description = delta.description;
            }
            if (delta.detail !== undefined) {
                entry.detail = delta.detail;
            }
            if (delta.tags !== undefined) {
                entry.tags = delta.tags;
            }
        }
    });
    await model.vdom.render();
}
async function deleteEntry(model, id) {
    await deleteEntryAPI(model.date, id);
    model.entries = model.entries.filter(entry => entry.id !== id);
    await model.vdom.render();
}
async function checkEntry(model, id, check = true) {
    let completedDate = null;
    if (check) {
        console.log('check');
        let nowDate = new Date();
        let modelDate = new Date(model.date + "T00:00:00");
        let date = nowDate < modelDate ? modelDate : nowDate;
        console.log('now', nowDate, 'model', modelDate, 'd', date);
        completedDate = dateToLocalISOString(date).split('T')[0];
    }
    console.log(completedDate);
    await updateEntryAPI(model.date, id, { completedDate: completedDate });
    model.entries.forEach(entry => {
        if (entry.id === id) {
            entry.completedDate = completedDate;
        }
    });
    await model.vdom.render();
}
async function checkAllEntries(model, allCompleted) {
    let nowDate = new Date();
    let modelDate = new Date(model.date + "T00:00:00");
    let date = nowDate < modelDate ? modelDate : nowDate;
    let formatted = dateToLocalISOString(date).split('T')[0];
    let completedDate = allCompleted ? formatted : null;
    await updateEntriesAPI(model.date, completedDate);
    model.entries.forEach(entry => {
        entry.completedDate = completedDate;
    });
    await model.vdom.render();
}
async function changeVisibility(model, visibility) {
    model.visibility = visibility;
    await model.vdom.render();
}
async function toggleCalendar(model, show) {
    if (show !== undefined) {
        model.showCalendar = show;
    }
    else {
        model.showCalendar = !model.showCalendar;
    }
    // reset date to the current date.
    if (!model.showCalendar) {
        const date = new Date(model.date + "T00:00:00");
        model.calendar.year = date.getFullYear();
        model.calendar.month = date.getMonth();
        const app = document.querySelector('body');
        if (app !== null) {
            app.focus();
        }
    }
    await model.vdom.render();
    if (model.showCalendar) {
        const el = document.querySelector('.calendar-modal');
        if (el !== null) {
            el.focus();
        }
    }
}
async function deleteTag(model, entry, tag) {
    entry.tags = entry.tags.filter(t => t !== tag);
    await updateEntryAPI(model.date, entry.id, { tags: entry.tags });
    await model.vdom.render();
}
async function toggleDetail(model, show) {
    if (show !== undefined) {
        model.showDetail = show;
    }
    else {
        model.showDetail = !model.showDetail;
    }
    await model.vdom.render();
    if (model.showDetail) {
        const el = document.querySelector('.detail-modal');
        if (el !== null) {
            el.focus();
        }
    }
}
async function nextCalendar(model) {
    let date = new Date(model.calendar.year, model.calendar.month + 1, 1);
    model.calendar.year = date.getFullYear();
    model.calendar.month = date.getMonth();
    await model.vdom.render();
}
async function prevCalendar(model) {
    let date = new Date(model.calendar.year, model.calendar.month - 1, 1);
    model.calendar.year = date.getFullYear();
    model.calendar.month = date.getMonth();
    await model.vdom.render();
}
function nextDay(model) {
    const d = new Date(model.date + "T00:00:00");
    d.setDate(d.getDate() + 1);
    const formatted = dateToLocalISOString(d).split('T')[0];
    navigate(`/${formatted}`);
}
function prevDay(model) {
    const d = new Date(model.date + "T00:00:00");
    d.setDate(d.getDate() - 1);
    const formatted = dateToLocalISOString(d).split('T')[0];
    navigate(`/${formatted}`);
}
/*
 * API
 */
async function addEntryAPI(date, id, description) {
    let result = await fetch(`/api/entry/${date}/${id}`, { method: "POST",
        headers: {
            "Content-Type": "application/json"
        },
        body: description
    });
    if (!result.ok) {
        throw new Error(`HTTP Error ${result.status}`);
    }
    return result.json();
}
async function updateEntryAPI(date, id, delta) {
    const formData = new URLSearchParams();
    if (delta.completedDate !== undefined && delta.completedDate !== null) {
        formData.set("completedDate", delta.completedDate);
    }
    if (delta.description !== undefined) {
        formData.set("description", String(delta.description));
    }
    if (delta.detail !== undefined) {
        formData.set("detail", String(delta.detail));
    }
    if (delta.tags !== undefined) {
        formData.set("tags", delta.tags.join(" "));
    }
    let result = await fetch(`/api/entry/${date}/${id}`, {
        method: "PUT",
        body: formData
    });
    if (!result.ok) {
        throw new Error(`HTTP Error ${result.status}`);
    }
    return result.json();
}
async function updateEntriesAPI(date, completedDate, description) {
    const formData = new URLSearchParams();
    if (completedDate !== null) {
        formData.set("completedDate", completedDate);
    }
    if (description !== undefined) {
        formData.set("description", String(description));
    }
    let result = await fetch(`/api/entry/${date}`, { method: "PUT", body: formData });
    if (!result.ok) {
        throw new Error(`HTTP Error ${result.status}`);
    }
    return result.json();
}
async function deleteEntryAPI(date, id) {
    let result = await fetch(`/api/entry/${date}/${id}`, { method: "DELETE" });
    if (!result.ok) {
        throw new Error(`HTTP Error ${result.status}`);
    }
    return result.json();
}
/*
 * Init
 */
export async function init(model, signal) {
    console.log('init todo');
    const date = new Date(model.date + "T00:00:00");
    model.calendar = {
        year: date.getFullYear(),
        month: date.getMonth()
    };
    model.entry = null;
    model.field = "";
    model.visibility = "All";
    model.showCalendar = false;
    model.showDetail = false;
    model.presence = await base64ToBitSet(model.presenceMap);
    model.touchstartX = 0;
    model.touchstartY = 0;
    model.touchendX = 0;
    model.touchendY = 0;
    console.log('main', model);
    // Keyboard Events
    document.body.addEventListener('keydown', (ev) => {
        if (["ArrowLeft", "ArrowRight"].includes(ev.key)) {
            ev.preventDefault();
        }
        switch (ev.key) {
            case "ArrowLeft":
                prevDay(model);
                break;
            case "ArrowRight":
                nextDay(model);
                break;
        }
    }, { signal });
    // Swipe Events
    const directions = {
        RIGHT: { x: 1, y: 0 },
        LEFT: { x: -1, y: 0 },
        UP: { x: 0, y: -1 },
        DOWN: { x: 0, y: 1 }
    };
    document.body.addEventListener('touchstart', (ev) => {
        model.touchstartX = ev.changedTouches[0].screenX;
        model.touchstartY = ev.changedTouches[0].screenY;
    }, { signal });
    document.body.addEventListener('touchend', (ev) => {
        model.touchendX = ev.changedTouches[0].screenX;
        model.touchendY = ev.changedTouches[0].screenY;
        const deltaX = model.touchendX - model.touchstartX;
        const deltaY = model.touchendY - model.touchstartY;
        const magnitude = Math.sqrt(deltaX * deltaX + deltaY * deltaY);
        // 50 pixels threshold
        if (magnitude < 120)
            return;
        const swipeX = deltaX / magnitude;
        const swipeY = deltaY / magnitude;
        let maxDot = -Infinity;
        let swipeDirection = '';
        for (const [key, dir] of Object.entries(directions)) {
            const dot = (swipeX * dir.x) + (swipeY * dir.y);
            if (dot > maxDot) {
                maxDot = dot;
                swipeDirection = key;
            }
        }
        switch (swipeDirection) {
            case "LEFT":
                nextDay(model);
                break;
            case "RIGHT":
                prevDay(model);
                break;
        }
    }, { signal });
    await model.vdom.render();
}
