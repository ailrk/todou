import { newVdom, initRouter, navigate } from "./vdom.js";
import * as Todo from './todo.js';
import * as Summary from './summary.js';
/*
 * Render
 */
function renderTodou(model) {
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
function dispatchEffects(model) {
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
async function routeDate(model, matched, _, signal) {
    const newDate = matched[0].replace("/", "").trim() ?? model.date;
    const response = await fetch(`/api/todo/${newDate}`);
    const data = await response.json();
    Todo.init(Object.assign(model, data), signal);
}
async function routeSummary(model, _matched, params, signal) {
    const date = params["date"] ?? model.date;
    model.date = date;
    const response = await fetch(`/api/summary?date=${date}`);
    const data = await response.json();
    Summary.init(Object.assign(model, data), signal);
}
async function routeMain(_model, _matched, params, signal) {
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
let routeController = new AbortController();
async function onRoute(model, vdom, route) {
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
    let date = window.__INITIAL__DATE__;
    if (window.location.pathname === '/') {
        navigate(`/${date}`);
    }
    let model = {
        tag: 'init',
        date: date,
    };
    let vdom = newVdom({
        model: model,
        render: renderTodou,
        mkEffects: dispatchEffects,
        root: document.getElementById("app")
    });
    // Start routing
    initRouter((route) => onRoute(model, vdom, route));
}
await main();
