import { VNode, h, VDom, createRef, navigate } from "./vdom.js";
import { base64ToBitSet, dateToLocalISOString, fmtYM, PresenceView, YMD } from "./lib.js";


type EntryId = number;


type Visibility = "All" | "Completed" | "Active";


interface Entry {
  id: EntryId;
  description: string;
  completedDate: string | null;
  detail: string;
  tags: string[];

  // local
  editingDescription: boolean;
  editingDetail: boolean;
}


function isCompleted(e: Entry): boolean { return e.completedDate !== null; }


export interface Model {
  // tag
  tag: "todo";

  // remote
  date: string;
  entries: Entry[];
  nextId: EntryId;

  // base64(compress(bytes)). Need to be decompressed into .presence
  presenceMap: string;
  firstDay?: string;

  // local
  visibility: Visibility;
  field: string;
  showCalendar: boolean;
  showDetail: boolean;
  presence: PresenceView;
  calendar: YMD;            // current calendar date
  entry: Entry | null;      // current focused entry
  touchstartX: number;
  touchendX: number;
  touchstartY: number;
  touchendY: number;

  // shared local
  vdom: VDom;
}


/*
 * Render
 */


export function renderTodo(model: Model): VNode {
  return (
    <div class="todou-container" tabindex="-1">
      <nav>
        <span onclick={(_: MouseEvent) => { toggleCalendar(model); }}> {model.date} </span>

        <div class="control">
          <span
            class="today-icon icon"
            onclick={(_: MouseEvent) => {  navigate(`/`); }}
          ></span>
          <span
            class="stat-icon icon"
            onclick={(_: MouseEvent) => {  navigate(`/summary?date=${model.date}`); }}
          ></span>
        </div>
      </nav>
      <section class="todoapp pg-todo">
        {renderInput(model)}
        {renderEntries(model)}
        {renderControls(model)}
      </section>
      { renderFooterInfo() }
      { model.showCalendar ? renderCalendarModal(model) : null }
      { model.showDetail   ? renderDetailModal(model)   : null }
    </div>
  );
}


function renderInput(model: Model): VNode {
  return (
    <header>
      <input
        class="new-todo"
        placeholder="What needs to be done?"
        autofocus
        value={model.field}
        name="newTodo"
        onkeydown={(ev: KeyboardEvent) => {
          if (ev.key === "Enter") {
            addEntry(model);
          }
        }}
        oninput={(ev: Event) => {
          updateField(model, (ev.target as HTMLInputElement).value);
        }}
      />
   </header>
  );
}


function renderEntries(model: Model): VNode {
  const { visibility, entries } = model;
  const allCompleted = entries.reduce(
    (completed, entry) => isCompleted(entry) && completed,
    false
  );
  const cssVisibility = entries.length === 0 ? "hidden" : "visible";

  const isVisible = (entry: Entry) => {
    switch (visibility) {
      case "Completed": return isCompleted(entry);
      case "Active": return !isCompleted(entry);
      default: return true;
    }
  };

  return (
    <section class="main" style={`visibility:${cssVisibility}`}>
      <input
        class="toggle-all"
        type="checkbox"
        checked={allCompleted}
        onclick={() => checkAllEntries(model, !allCompleted)}
      />
      <label for="toggle-all">Mark all as complete</label>
      <ul class="todo-list">
        {entries.filter(isVisible).map(entry => renderEntry(model, entry))}
      </ul>
    </section>
  );
}


function renderControls(model: Model): VNode {
  const { visibility, entries } = model;
  const entriesCompleted = entries.filter(isCompleted).length;
  const entriesLeft = entries.length - entriesCompleted;

  return (
    <footer class="footer" hidden={entries.length === 0}>
      {renderControlsCount(entriesLeft)}
      {renderControlsFilter(model, visibility)}
    </footer>
  );
}


function renderControlsCount(entriesLeft: number): VNode {
  return (
    <span class="todo-count">
      <strong>{entriesLeft}</strong> {entriesLeft === 1 ? " item" : " items"}
    </span>
  );
}


function renderControlsFilter(model: Model, visibility: Visibility): VNode {
  return (
    <ul class="filters">
      {visibilitySwap(model, "#/", "All", visibility)}
      {visibilitySwap(model, "#/active", "Active", visibility)}
      {visibilitySwap(model, "#/completed", "Completed", visibility)}
    </ul>
  );
}


function visibilitySwap(model: Model, uri: string, vis: Visibility, currentVis: Visibility): VNode {
  return (
    <li onclick={() => changeVisibility(model, vis)}>
      <a href={uri} class={vis === currentVis ? "selected" : ""}>
        {vis}
      </a>
    </li>
  );
}


function renderFooterInfo(): VNode {
  return (
    <footer class="info">
      <p>Double click to edit a todo</p>
    </footer>
  );
}


function renderEntry(model: Model, entry: Entry): VNode {
  const classes = [ isCompleted(entry) ? "completed" : "" ].filter(Boolean).join(" ");

  return (
    <li key={`todo-${entry.id}`} class="entry-description ">
      <input
        class="toggle"
        type="checkbox"
        checked={isCompleted(entry)}
        onclick={() => { checkEntry(model, entry.id, !isCompleted(entry)) }} />
      <label
          class={classes}
          onclick={() => {
          model.entry = entry;
          toggleDetail(model);
      }}>{entry.description}</label>

      <div class="entry-tags">
        {entry.tags.map(tag => renderTag(model, entry, tag, false))}
      </div>
      <button class="destroy" onclick={() => deleteEntry(model, entry.id)} />
      </li>
    );
}


function renderTag(model: Model, entry: Entry, tag: string, canDelete: boolean = true): VNode {
  return (
    <div key={`todo-detail-tag-${tag}`} class="tag">
      <span>{tag}</span>
      { !canDelete ?  null :
        <button
          class="delete-tag"
          onclick={() => deleteTag(model, entry, tag)}>
        </button>
      }
    </div>
  );
}


function renderTags(model: Model, entry: Entry): VNode {

  async function onKeydown(ev: KeyboardEvent) {
    if (ev.key === "Enter") {
      const input = ev.target as HTMLInputElement;
      const newTag = input.value.trim();
      if (newTag) {
        if (entry.tags.includes(newTag)) {
          input.classList.add('error');
          setTimeout(() => {
            input.classList.remove('error');
          }, 800);
        } else {
          entry.tags.push(newTag);
          input.value = "";
          await updateEntryAPI(model.date, entry.id, { tags: entry.tags });
        }
      }
    }
    await model.vdom.render();
  }

  return (
    <div class="detail-tags">
      {entry.tags.map(tag => renderTag(model, entry, tag))}
      <div class="add-tag-container">
        <input
          type="text"
          placeholder="+ Tag"
          onkeydown={onKeydown}
        />
      </div>
    </div>
  );
}


function renderDetailDescription(model: Model) {
  if (model.entry === null) return "No Entry";
  let entry    = model.entry;
  let inputRef = createRef();

  const classes =
    !model.entry ? "" :
    [ isCompleted(model.entry) ? "completed" : "",
      model.entry.editingDescription ? "editing" : "non-editing"
    ].filter(Boolean).join(" ");

  function onCheck() {
    checkEntry(model, entry.id, !isCompleted(entry))
  }

  function onClick() {
    editingEntryDescription(model, entry.id, true);

    if (inputRef.current) {
      let el = inputRef.current as HTMLElement;
      el.focus();
    }
  }

  function onKeydown(ev: KeyboardEvent) {
    if (ev.key === "Enter" && !ev.shiftKey || ev.key === "Escape") {
      ev.preventDefault();
      editingEntryDescription(model, entry.id, false);
    }
  }

  function onInput(ev: Event) {
    updateEntry(model, entry.id, { description: (ev.target as HTMLInputElement).value });
  }

  function onBlur() {
    editingEntryDescription(model, entry.id, false);
  }

  function onDestroy() {
    deleteEntry(model, entry.id);
    toggleDetail(model, false);
  }

  return (
    <div class={ "entry-description edit " + classes }>
      <input
        class="toggle"
        type="checkbox"
        checked={isCompleted(entry)}
        onclick={onCheck} />
      <input
        name="description"
        value={entry.description}
        ref={inputRef}
        id={`todo-description-${entry.id}`}
        onclick={onClick}
        onkeydown={onKeydown}
        oninput={onInput}
        onblur={onBlur}
      />
      <button class="destroy" onclick={onDestroy} />
    </div>
    );
}


function renderDetail(model: Model) {
  if (model.entry === null) return "No Entry";
  let entry       = model.entry;
  let textAreaRef = createRef();

  const classes =
    !model.entry ? "" :
    [ model.entry.editingDetail ? "editing" : "non-editing"
    ].filter(Boolean).join(" ");

  function onClick() {
    editingEntryDetail(model, entry.id, true);
  }

  function onKeydown(ev: KeyboardEvent) {
    if (ev.key === "Escape") {
      ev.preventDefault();
      ev.stopPropagation();
      editingEntryDetail(model, entry.id, false);
    }
  }

  function onInput(ev: Event) {
    updateEntry(model, entry.id, { detail: (ev.target as HTMLInputElement).value } );

    if (textAreaRef.current) {
      let el = textAreaRef.current as HTMLElement;
      el.focus();
    }
  }

  function onBlur() {
    editingEntryDetail(model, entry.id, false);
  }

  return (
    <div class={ "entry-detail edit " + classes}>
      <textarea
        name="detail"
        value={entry.detail}
        ref={textAreaRef}
        id={`todo-detail-${entry.id}`}
        onclick={onClick}
        onkeydown={onKeydown}
        oninput={onInput}
        onblur={onBlur} />
    </div>
  )
}


function renderCompletedDate(model: Model) {
  if (model.entry === null) {
    return "Empty Entry";
  }

  let entry = model.entry;
  let inputRef = createRef();
  const isNumeric = (str: string) => str.length > 0 && [...str].every(c => c >= '0' && c <= '9');

  function isValidDate(d: string) {
    let ds = d.trim().split("-").filter(s => s !== "");
    if (ds.length !== 3) return false;
    if (ds[0].length !== 4 || !isNumeric(ds[0])) return false;
    if (ds[1].length !== 2 || !isNumeric(ds[1])) return false;
    if (ds[2].length !== 2 || !isNumeric(ds[2])) return false;
    if (new Date(d) < new Date(model.date)) return false;
    return true;
  }

  // Cascade to blur
  async function onKeydown(ev: KeyboardEvent) {
    if (ev.key === "Enter") {
      let input = ev.target as HTMLInputElement;
      input.blur();
    }
  }

  async function onBlur(ev: Event) {
    let input = ev.target as HTMLInputElement;
    let completedDate = input.value.trim();
    if (isValidDate(completedDate)) {
      entry.completedDate = completedDate;
      editingEntryDetail(model, entry.id, false);
    } else {
      input.classList.add('error');
      setTimeout(() => {
        input.classList.remove('error');
      }, 800);
    }
  }

  return (
    model.entry.completedDate !== null
      ?
        <div class="detail-completed-date-container">
          <input
            type="text"
            ref={inputRef}
            placeholder="completed at"
            onkeydown={onKeydown}
            onblur={onBlur}
            value={model.entry.completedDate}
          />
        </div>
      : null
  );
}


function renderDetailModal(model: Model): VNode {
  if (model.entry === null) {
    return "Empty Entry";
  }

  let contentRef = createRef();

  return (
    <div
      class="detail-modal modal"
      tabindex="-1"
      onkeydown={(ev: KeyboardEvent) => {
        if (["ArrowLeft", "ArrowRight"].includes(ev.key)) {
          ev.stopPropagation();
        }
      }}
      onclick={(ev: MouseEvent) => {
        let path = ev.composedPath();
        if (contentRef.current && path.includes(contentRef.current as HTMLElement)) {
            return;
        }
        toggleDetail(model, false)
      }}>
      <div class="detail-content" ref={contentRef}>
        <div class="detail-header">
          { renderDetailDescription(model) }
          { renderCompletedDate(model) }
          { renderTags(model, model.entry!) }
        </div>
        <div class="detail-body">
          { renderDetail(model) }
        </div>
      </div>
    </div>
  );
}


function renderCalendarModal(model: Model): VNode {
  const firstDay       = new Date(model.calendar.year, model.calendar.month, 1);
  const lastDay        = new Date(model.calendar.year, model.calendar.month + 1, 0);
  const daysInMonth    = lastDay.getDate();
  const firstDayOfWeek = firstDay.getDay();
  const formatted      = fmtYM(model.calendar);
  const date           = new Date (model.date + "T00:00:00");

  function dateEq(i: number, calendar: YMD, d: Date) {
    return calendar.year === d.getFullYear() &&
      calendar.month === d.getMonth() &&
      i === d.getDate();
  }

  function today(i: number) {
    let now = new Date();
    if (dateEq(i, model.calendar, now))
      return " cal-today"
    else
      return ""
  }

  function current(i: number) {
    if (dateEq(i, model.calendar, date))
      return " cal-current"
    else
      return ""
  }

  function presence(i: number) {
    // immediately set current non-mempty todo as presence
    if (dateEq(i, model.calendar, date)) {
      if (model.entries.length > 0) {
        if (model.entries.every(isCompleted)) {
          return " cal-completed";
        }
        return " cal-presence";
      }
    }

    if (model.firstDay === "") return "";

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

  function jump(i: number) {
    let url = "";
    url += `/${model.calendar.year}-`;
    url += `${String(model.calendar.month+1).padStart(2, '0')}-`;
    url += `${String(i).padStart(2, '0')}`;
    navigate(url);
  }

  function renderDay(i: number) {
    return (
      <li
        class={today(i) + " " + current(i) + " " + presence(i)}
        style={ i == 1 ? `grid-column-start: ${firstDayOfWeek + 1}` : ""}
        onclick={() => jump(i)}>
        { i }
      </li>
    );
  }

  function renderDays() {
    return Array.from({ length: daysInMonth }, (_, i) => i + 1).map(renderDay)
  }

  return (
    <div
      class="calendar-modal modal"
      tabindex="-1"
      onkeydown={(ev: KeyboardEvent) => {
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
      }}
      onclick={(ev: MouseEvent) => {
        if (document.querySelector('.calendar-content')!.contains(ev.target as Node)) return;
        toggleCalendar(model, false)
      }} >
        <div class="calendar-content">
          <span class="calendar-header">
            <button onclick={(_: MouseEvent) => { prevCalendar(model)} }/>
            <h1>{formatted}</h1>
            <button onclick={(_: MouseEvent) => { nextCalendar(model)} }/>
          </span>

        <ol class="calendar">
          <li class="day-name">Sun</li> <li class="day-name">Mon</li> <li class="day-name">Tue</li>
          <li class="day-name">Wed</li> <li class="day-name">Thu</li> <li class="day-name">Fri</li>
          <li class="day-name">Sat</li>
          { renderDays() }
        </ol>
      </div>
    </div>
  );
}



/*
 * Model
 */


interface EditingDelta {
  completedDate?: string | null;
  description?: string;
  detail?: string;
  tags?: string[]
}


async function addEntry(model: Model) {
  if (model.field === "") return;
  let newEntry = {
      id: model.nextId,
      description: model.field,
      detail: "",
      tags: [],
      editingDescription: false,
      editingDetail: false,
      completedDate: null
    }
  await addEntryAPI(model.date, newEntry.id, newEntry.description);
  model.nextId++;
  model.field = "";
  model.entries.push(newEntry);
  await model.vdom.render();
}


async function updateField(model: Model, str: string) {
  model.field = str;
  await model.vdom.render();
}


async function editingEntryDescription(model: Model, id: EntryId, isEditing: boolean = false) {
  let entry = model.entries.filter(e => e.id === id).at(0)
  if (!entry) return;

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



async function editingEntryDetail(model: Model, id: EntryId, isEditing: boolean = false) {
  let entry = model.entries.filter(e => e.id === id).at(0)
  if (!entry) return;

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


async function updateEntry(model: Model, id: EntryId, delta: EditingDelta) {
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
  })
  await model.vdom.render();
}


async function deleteEntry(model: Model, id: EntryId) {
  await deleteEntryAPI(model.date, id);
  model.entries = model.entries.filter(entry => entry.id !== id);
  await model.vdom.render();
}


async function checkEntry(model: Model, id: EntryId, check: boolean = true) {
  let completedDate = null;
  if (check) {
    console.log('check')
    let nowDate   = new Date();
    let modelDate = new Date(model.date + "T00:00:00");
    let date      = nowDate < modelDate ? modelDate : nowDate;
    console.log('now', nowDate, 'model', modelDate, 'd', date);
    completedDate = dateToLocalISOString(date).split('T')[0];
  }
  console.log(completedDate);

  await updateEntryAPI(model.date, id, { completedDate: completedDate });
  model.entries.forEach(entry => {
    if (entry.id === id) {
      entry.completedDate = completedDate
    }
  });
  await model.vdom.render();
}


async function checkAllEntries(model: Model, allCompleted?: boolean) {
  let nowDate       = new Date();
  let modelDate     = new Date(model.date + "T00:00:00");
  let date          = nowDate < modelDate ? modelDate : nowDate;
  let formatted     = dateToLocalISOString(date).split('T')[0];
  let completedDate = allCompleted ? formatted : null;
  await updateEntriesAPI(model.date, completedDate);
  model.entries.forEach(entry => {
    entry.completedDate = completedDate
  });
  await model.vdom.render();
}


async function changeVisibility(model: Model, visibility: Visibility) {
  model.visibility = visibility;
  await model.vdom.render();
}


async function toggleCalendar(model: Model, show?: boolean) {
  if (show !== undefined) {
    model.showCalendar = show;
  } else {
    model.showCalendar = !model.showCalendar;
  }

  // reset date to the current date.
  if (!model.showCalendar) {
    const date = new Date(model.date + "T00:00:00");
    model.calendar.year = date.getFullYear();
    model.calendar.month = date.getMonth();

    const app = document.querySelector('body');
    if (app !== null) {
      (app as HTMLElement).focus();
    }
  }

  await model.vdom.render();

  if (model.showCalendar) {
    const el = document.querySelector('.calendar-modal');
    if (el !== null) {
      (el as HTMLElement).focus();
    }
  }
}


async function deleteTag(model: Model, entry: Entry, tag: string) {
  entry.tags = entry.tags.filter(t => t !== tag);

  await updateEntryAPI(model.date, entry.id, { tags: entry.tags });
  await model.vdom.render();
}


async function toggleDetail(model: Model, show?: boolean) {
  if (show !== undefined) {
    model.showDetail = show;
  } else {
    model.showDetail = !model.showDetail;
  }

  await model.vdom.render();

  if (model.showDetail) {
    const el = document.querySelector('.detail-modal');
    if (el !== null) {
      (el as HTMLElement).focus();
    }
  }
}


async function nextCalendar(model: Model) {
  let date = new Date(model.calendar.year, model.calendar.month + 1, 1);
  model.calendar.year = date.getFullYear();
  model.calendar.month = date.getMonth();
  await model.vdom.render()
}


async function prevCalendar(model: Model) {
  let date = new Date(model.calendar.year, model.calendar.month - 1, 1);
  model.calendar.year = date.getFullYear();
  model.calendar.month = date.getMonth();
  await model.vdom.render()
}


function nextDay(model: Model) {
  const d = new Date(model.date + "T00:00:00");
  d.setDate(d.getDate() + 1);
  const formatted = dateToLocalISOString(d).split('T')[0];
  navigate(`/${formatted}`)
}


function prevDay(model: Model) {
  const d = new Date(model.date + "T00:00:00");
  d.setDate(d.getDate() - 1);
  const formatted = dateToLocalISOString(d).split('T')[0];
  navigate(`/${formatted}`)
}


/*
 * API
 */


async function addEntryAPI(date: string, id: number, description: string) {
  let result = await fetch(`/api/entry/${date}/${id}`,
    { method: "POST",
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


async function updateEntryAPI(date: string, id: number, delta: EditingDelta) {
  const formData = new URLSearchParams();
  if (delta.completedDate !== undefined && delta.completedDate !== null) {
    formData.set("completedDate", delta.completedDate)
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
    method: "PUT" ,
    body: formData
  });
  if (!result.ok) {
    throw new Error (`HTTP Error ${result.status}`);
  }
  return result.json();
}


async function updateEntriesAPI(date: string, completedDate: string | null, description?: string) {
  const formData = new URLSearchParams();
  if (completedDate !== null) {
    formData.set("completedDate", completedDate)
  }

  if (description !== undefined) {
    formData.set("description", String(description));
  }

  let result = await fetch(`/api/entry/${date}`, { method: "PUT", body: formData });
  if (!result.ok) {
    throw new Error (`HTTP Error ${result.status}`);
  }
  return result.json();
}


async function deleteEntryAPI(date: string, id: number) {
  let result = await fetch(`/api/entry/${date}/${id}`, { method: "DELETE" });
  if (!result.ok) {
    throw new Error(`HTTP Error ${result.status}`);
  }
  return result.json();
}


/*
 * Init
 */


export async function init(model: Model, signal: AbortSignal) {
  console.log('init todo')
  const date = new Date(model.date + "T00:00:00");

  model.calendar = {
    year: date.getFullYear(),
    month: date.getMonth()
  }

  model.entry        = null;
  model.field        = "";
  model.visibility   = "All";
  model.showCalendar = false;
  model.showDetail   = false;
  model.presence     = await base64ToBitSet(model.presenceMap);
  model.touchstartX  = 0;
  model.touchstartY  = 0;
  model.touchendX    = 0;
  model.touchendY    = 0;

  console.log('main', model);

  // Keyboard Events
  document.body.addEventListener('keydown', (ev: KeyboardEvent) => {
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
    LEFT:  { x: -1, y: 0 },
    UP:    { x: 0, y: -1 },
    DOWN:  { x: 0, y: 1 }
  };

  document.body.addEventListener('touchstart', (ev: TouchEvent) => {
    model.touchstartX = ev.changedTouches[0].screenX;
    model.touchstartY = ev.changedTouches[0].screenY;
  }, { signal });

  document.body.addEventListener('touchend', (ev: TouchEvent) => {
    model.touchendX = ev.changedTouches[0].screenX;
    model.touchendY = ev.changedTouches[0].screenY;

    const deltaX = model.touchendX - model.touchstartX;
    const deltaY = model.touchendY - model.touchstartY;

    const magnitude = Math.sqrt(deltaX * deltaX + deltaY * deltaY);

    // 50 pixels threshold
    if (magnitude < 120) return;

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
        case "LEFT": nextDay(model); break;
        case "RIGHT": prevDay(model); break;
    }
  }, { signal });

  await model.vdom.render();
}
