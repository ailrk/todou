import { newVdom, VDom, VNode, initRouter, navigate, Route } from "./vdom.js";
import * as Todo from './todo.js';
import * as Summary from './summary.js';



type Model
  = Todo.Model
  | Summary.Model
  | {tag: 'init', date: string, vdom?: VDom};


/*
 * Render
 */


function renderTodou(model: Model): VNode | null {
  switch (model.tag) {
    case "todo":
      return Todo.renderTodo(model);
    case "summary":
      return Summary.renderSummary(model);
    case "init":
      return null;
  }
}


/*
 * Effects
 */


function dispatchEffects(model: Model) {
  switch (model.tag) {
    case "todo":
      return [];
    case "summary":
      return Summary.mkEffects(model);
    case "init":
      return [];
  }
}


/*
 * Routers
 */


async function routeDate(model: Model, matched: RegExpMatchArray, _: Record<string, string>, signal: AbortSignal) {
  const newDate = matched[0].replace("/", "").trim() ?? model.date;
  const response = await fetch(`/api/todo/${newDate}`);
  const data = await response.json() as Todo.Model;

  Todo.init(Object.assign(model, data), signal);
}

async function routeSummary(model: Model, _matched: RegExpMatchArray, params: Record<string, string>, signal: AbortSignal) {
  const date = params["date"] ?? model.date;

  model.date = date;

  const response = await fetch(`/api/summary?date=${date}`);
  const data = await response.json() as Summary.Model;

  Summary.init(Object.assign(model, data), signal);
}


async function routeMain(_model: Model, _matched: RegExpMatchArray, params: Record<string, string>, signal: AbortSignal) {
  window.location.href = "/";
}


const routes = [
  /* Summary page */
  { path: /^\/summary(\?.*)?$/, handler: routeSummary },

  /* Render todo for a date */
  { path: /^\/(\d{4}-\d{2}-\d{2})$/, handler: routeDate },

  { path: /^\/?$/, handler: routeMain },
];


/*
 * Main
 */

let routeController: AbortController = new AbortController();


async function onRoute(model: Model, vdom: VDom, route: Route) {

  routeController.abort();
  routeController = new AbortController();
  const { signal } = routeController;

  for (const r of routes) {
    const match = route.path.match(r.path);
    if (match) {
      await r.handler(model, match, route.params, signal);
      await vdom.render();
      return;
    }
  }
  console.error("No frontend route matched:", route.path);
}


async function main() {
  let date = (window as any).__INITIAL__DATE__ as string;

  if (window.location.pathname === '/') {
    navigate(`/${date}`);
  }

  let model = {
    tag: 'init',
    date: date,
  } as Model;

  let vdom = newVdom({
    model: model,
    render: renderTodou,
    mkEffects: dispatchEffects,
    root: document.getElementById("app")!
  });

  // Start routing
  initRouter((route) => onRoute(model, vdom, route));
}


await main();
