import { h, navigate } from "./vdom.js";
import { base64ToBitSet, fmtYM } from "./lib.js";
;
/*
 * Render
 */
export function renderSummary(model) {
    return (h("div", { class: "todou-container", tabindex: "-1" },
        h("nav", null,
            h("span", null,
                " ",
                model.date.substring(0, 7),
                " "),
            h("div", { class: "control" },
                h("span", { class: "today-icon icon", onclick: (_) => { navigate(`/`); } }),
                h("span", { class: "back-icon icon", onclick: (_) => { navigate(`/${model.date}`); } }))),
        h("section", { class: "todoapp pg-stat" },
            renderCFDWidget(model),
            renderCalendarWidget(model)),
        renderFooterInfo()));
}
function renderCFDWidget(model) {
    return (h("section", { class: "cfd-widget widget" },
        renderCFDControls(model),
        renderCFD(),
        renderCFDFooter(model)));
}
function renderCFDControls(model) {
    async function showNMonths(i, ev) {
        ev.preventDefault();
        switch (i) {
            case 1:
                model.cfd = model.cfd1Month;
                break;
            case 2:
                model.cfd = model.cfd2Month;
                break;
            case 3:
                model.cfd = model.cfd3Month;
                break;
            default:
                model.cfd = model.cfd1Month;
                break;
        }
        await model.vdom.render();
    }
    return (h("header", { class: "cfd-controls" },
        h("div", { class: "dropdown" },
            h("button", { class: "dropbtn" },
                model.cfd.from,
                " - ",
                model.cfd.to),
            h("div", { class: "dropdown-content" },
                h("a", { href: "#", onclick: (ev) => showNMonths(1, ev) }, "1 Months"),
                h("a", { href: "#", onclick: (ev) => showNMonths(2, ev) }, "2 Months"),
                h("a", { href: "#", onclick: (ev) => showNMonths(3, ev) }, "3 Months"))),
        h("div", { class: "legend" },
            h("span", { style: "color: #2ecc71; margin-right: 10px;" }, "\u25CF Completed"),
            h("span", { style: "color: #3498db;" }, "\u25CF Ongoing"))));
}
function renderCFD() {
    return (h("section", { class: "cfd-container" },
        h("canvas", { id: "cfd-canvas" }),
        h("canvas", { id: "cfd-canvas-datapoints" })));
}
function renderCFDFooter(model) {
    const last = model.cfd.content[model.cfd.content.length - 1];
    if (!last)
        return h("footer", { class: "cfd-footer" });
    return (h("footer", { class: "cfd-footer" },
        h("div", null,
            h("strong", null, "Total:"),
            " ",
            last.completed + last.ongoing),
        h("div", null,
            h("strong", null, "Done:"),
            " ",
            last.completed),
        h("div", null,
            h("strong", null, "Backlog:"),
            " ",
            last.ongoing)));
}
function renderCalendarWidget(model) {
    return (h("section", { class: "calendar-widget widget" }, renderCalendar(model)));
}
function renderCalendar(model) {
    const firstDay = new Date(model.calendar.year, model.calendar.month, 1);
    const lastDay = new Date(model.calendar.year, model.calendar.month + 1, 0);
    const daysInMonth = lastDay.getDate();
    const firstDayOfWeek = firstDay.getDay();
    const formatted = fmtYM(model.calendar);
    function today(i) {
        let now = new Date();
        if (model.calendar.year === now.getFullYear() &&
            model.calendar.month === now.getMonth() &&
            i === now.getDate())
            return " cal-today";
        else
            return "";
    }
    function presence(i) {
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
    return (h("div", { class: "calendar-content" },
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
            Array
                .from({ length: daysInMonth }, (_, i) => i + 1)
                .map(i => {
                return (h("li", { class: today(i) + " " + presence(i), style: i == 1 ? `grid-column-start: ${firstDayOfWeek + 1}` : "", onclick: () => {
                        jump(i);
                    } }, i));
            }))));
}
function renderFooterInfo() {
    return (h("footer", { class: "info" },
        h("p", null, "Todou Summary")));
}
function setupCanvas(canvas, model) {
    const container = canvas.parentElement;
    const ctx = canvas.getContext('2d');
    if (!ctx)
        return;
    // Force the canvas to match the container's physical size
    const dpr = window.devicePixelRatio || 1;
    const rect = container.getBoundingClientRect();
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    // Keep the visual size fixed via CSS
    canvas.style.width = `${rect.width}px`;
    canvas.style.height = `${rect.height}px`;
    // Scale context for High-DPI sharpness
    ctx.scale(dpr, dpr);
    const padding = 25;
    const w = rect.width;
    const h = rect.height;
    const maxY = Math.max(...model.cfd.content.map(d => d.completed + d.ongoing));
    const getX = (i) => padding + (i / (model.cfd.content.length - 1)) * (w - padding * 2);
    const getY = (v) => h - padding - (v / maxY) * (h - padding * 2);
    // "w" and "h" are the logical CSS pixels
    return {
        w: rect.width,
        h: rect.height,
        rect: rect,
        ctx: ctx,
        maxY: maxY,
        getX: getX,
        getY: getY,
        cfd: model.cfd,
        padding: padding
    };
}
async function drawCFD(model) {
    let c = setupCanvas(document.getElementById("cfd-canvas"), model);
    if (!c)
        return;
    let { w, h, ctx, maxY, getX, getY, padding, cfd } = c;
    // Draw Background Grid
    ctx.strokeStyle = "#e0e0e0";
    ctx.lineWidth = 1;
    ctx.beginPath();
    // Horizontal Grid Lines (Y-Axis)
    const ticks = 5;
    for (let i = 0; i <= ticks; i++) {
        const val = (Math.trunc(maxY / ticks)) * i;
        const y = Math.floor(getY(val));
        ctx.moveTo(padding, y);
        ctx.lineTo(w - padding, y);
        ctx.fillStyle = "#777";
        ctx.fillText(val.toString(), padding - 18, y);
    }
    // Vertical Grid Lines (X-Axis) - matching data points
    const gap = Math.floor(cfd.content.length / 32) + 1; // gap by month
    cfd.content.forEach((val, i) => {
        const x = getX(i);
        if (i % gap === 0) {
            ctx.moveTo(x, padding);
            ctx.lineTo(x, h - padding);
            ctx.stroke();
        }
        let day = val.date.substring(5, 10);
        ctx.strokeStyle = "#e0e0e0";
        if (i === 0)
            ctx.fillText(day, x - 5, h - padding + 10);
        if (i === Math.trunc((cfd.content.length - 1) / 4))
            ctx.fillText(day, x - 5, h - padding + 10);
        if (i === Math.trunc((cfd.content.length - 1) / 2))
            ctx.fillText(day, x - 5, h - padding + 10);
        if (i === Math.trunc((cfd.content.length - 1) * 3 / 4))
            ctx.fillText(day, x - 5, h - padding + 10);
        if (i === cfd.content.length - 1)
            ctx.fillText(day, x - 5, h - padding + 10);
    });
    ctx.stroke();
    // Draw Ongoing (Blue) on top
    ctx.fillStyle = "rgba(52, 152, 219, 0.5)";
    ctx.beginPath();
    ctx.moveTo(getX(0), h - padding);
    cfd.content.forEach((d, i) => ctx.lineTo(getX(i), getY(d.completed + d.ongoing)));
    ctx.lineTo(getX(cfd.content.length - 1), h - padding);
    ctx.closePath();
    ctx.fill();
    // Draw "Completed" Area (The Green Part)
    // To fill, you must moveTo bottom-left, lineTo points, then closePath
    ctx.fillStyle = "rgba(86, 218, 44, 0.5)";
    ctx.beginPath();
    ctx.moveTo(getX(0), h - padding); // Start at bottom
    cfd.content.forEach((d, i) => ctx.lineTo(getX(i), getY(d.completed)));
    ctx.lineTo(getX(cfd.content.length - 1), h - padding); // End at bottom
    ctx.closePath(); // This connects back to the start and fills
    ctx.fill();
    // Draw circles for Ongoing (Blue) data points
    cfd.content.forEach((d, i) => {
        ctx.fillStyle = "rgba(52, 152, 219, 1)"; // Fully opaque for better visibility
        ctx.beginPath();
        ctx.arc(getX(i), getY(d.completed + d.ongoing), 2, 0, Math.PI * 2);
        ctx.closePath();
        ctx.fill();
    });
    // Draw circles for Completed (Green) data points
    ctx.fillStyle = "#2ecc71";
    cfd.content.forEach((d, i) => {
        ctx.beginPath();
        ctx.arc(getX(i), getY(d.completed), 2, 0, Math.PI * 2);
        ctx.closePath();
        ctx.fill();
    });
    // Draw circle for tasks completed after this window
    ctx.fillStyle = "#af2f2f6e";
    let lastI = cfd.content.length - 1;
    let last = cfd.content[lastI];
    ctx.beginPath();
    ctx.arc(getX(lastI), getY(last.completed + cfd.completedAfter), 2, 0, Math.PI * 2);
    ctx.closePath();
    ctx.fill();
}
function drawTooltip(ctx, x, y, w, text) {
    const padding = 8;
    const fontSize = 12;
    ctx.font = `${fontSize}px sans-serif`;
    // Measure text to size the box
    const width = ctx.measureText(text).width + padding * 2;
    const height = fontSize + padding * 2;
    let x0 = x + 10;
    let y0 = y - 10;
    if (x0 + width > w) {
        x0 = x0 - width;
    }
    if (y0 - height < 0) {
        y0 = y + 10;
    }
    // Draw the bubble (Rounded rectangle)
    ctx.fillStyle = "rgba(0, 0, 0, 0.6)";
    ctx.beginPath();
    ctx.roundRect(x0, y0 - height, width, height, 5);
    ctx.fill();
    // Draw the text
    ctx.fillStyle = "#fff";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x0 + padding, y0 - height / 2);
}
function drawCFDDatapoints(canvas, model, evt) {
    let deltaX = 2;
    let deltaY = 10;
    let c = setupCanvas(canvas, model);
    if (!c)
        return;
    let { w, h, ctx, getX, getY, cfd, rect } = c;
    // Calculate mouse position relative to the canvas
    const x = evt ? evt.clientX - rect.left : 0;
    const y = evt ? evt.clientY - rect.top : 0;
    // Clear the canvas before each redraw
    ctx.clearRect(0, 0, w, h);
    const hit = (x, n, str) => {
        ctx.strokeStyle = "#fff";
        const y = getY(n);
        drawTooltip(ctx, x, y, w, `${str}, ${n}`);
        ctx.beginPath();
        ctx.arc(x, y, 4, 0, Math.PI * 2);
        ctx.closePath();
        ctx.stroke();
    };
    let lastI = cfd.content.length - 1;
    let last = cfd.content[lastI];
    cfd.content.forEach((d, i) => {
        let x0 = getX(i);
        let y0 = getY(d.completed);
        let y1 = getY(d.completed + d.ongoing);
        let y2 = getY(d.completed + cfd.completedAfter);
        let f1 = x < x0 + deltaX && x > x0 - deltaX && y < y0 + deltaY && y > y0 - deltaY;
        let f2 = x < x0 + deltaX && x > x0 - deltaX && y < y1 + deltaY && y > y1 - deltaY;
        let f3 = x < x0 + deltaX && x > x0 - deltaX && y < y2 + deltaY && y > y2 - deltaY;
        if (i === lastI && f3) {
            hit(getX(lastI), last.completed + cfd.completedAfter, "total completed");
        }
        else if (f1 && f2) {
            if (Math.abs(y0 - y) < Math.abs(y1 - y)) {
                hit(getX(i), d.completed, d.date);
            }
            else {
                hit(getX(i), d.completed + d.ongoing, d.date);
            }
        }
        else {
            if (f1) {
                hit(getX(i), d.completed, d.date);
            }
            if (f2) {
                hit(getX(i), d.completed + d.ongoing, d.date);
            }
        }
    });
}
/*
 * Model
 */
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
/*
 * Effects
 */
export function mkEffects(model) {
    return [
        async () => await drawCFD(model),
        async () => {
            const canvas = document.getElementById("cfd-canvas-datapoints");
            drawCFDDatapoints(canvas, model);
            canvas.addEventListener('mousemove', evt => drawCFDDatapoints(canvas, model, evt));
        }
    ];
}
/*
 * Init
 */
export async function init(model, signal) {
    console.log('init summary');
    model.cfd = model.cfd1Month;
    let date = new Date(model.date + "T00:00:00"); // use local time
    model.calendar = {
        year: date.getFullYear(),
        month: date.getMonth()
    };
    model.presence = await base64ToBitSet(model.presenceMap);
    // Register top level event listeners
    document.body.addEventListener('wheel', (_) => {
        requestAnimationFrame(async () => await drawCFD(model));
    }, { signal });
    await model.vdom.render();
}
