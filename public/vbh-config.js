/* ═══════════════════════════════════════════════════════════════════════════
   vbh-config.js — the ONE config file for every hub page · build shell-v1
   ───────────────────────────────────────────────────────────────────────────
   Edit lists here; nothing else needs to change when the team, the pages, or
   the dropdown options change. Loaded before vbh-shell.js on every page.

   Sections
     1. connection + build
     2. PAGES registry   → drives the site nav, page headers, gate, hub tiles
     3. option lists     → dropdowns across leads / intake / projects
     4. roles & rosters  → work-order requestors, crew, meeting team
     5. window.VBH_CONFIG (read by meeting.html) and legacy globals
   ═══════════════════════════════════════════════════════════════════════════ */
/* Named roles. Pages reference roles, never people, so a personnel change is
   a one-line edit here. */
const VBH_ROLES = {
  opsDirector: { title: 'Director of Operations', name: 'Jordan Hefner',      email: 'jordan.hefner@vanbuskirkco.com' },
  ceo:         { title: 'CEO',                    name: 'Steve Van Buskirk',  email: 'Steve@vanbuskirkco.com' },
  coo:         { title: 'COO',                    name: 'Kelly Boyd',         email: 'kelly.boyd@vanbuskirkco.com' }
};

const VBH = {
  BUILD: 'shell-v3',
  ROLES: VBH_ROLES,

  /* Weekly Executive Update (weeklyupdate.html): who it goes to and who signs it. */
  EXEC_UPDATE: {
    recipients: [VBH_ROLES.ceo, VBH_ROLES.coo],
    sender: VBH_ROLES.opsDirector,
    weekday: 3,          /* Wednesday */
    time: '4:30 PM'
  },

  /* ── 1 · connection ─────────────────────────────────────────────────────
     The anon key is public by design (it ships to every browser); row-level
     security in Supabase is what protects the data. Never put a service-role
     key here. */
  SUPABASE_URL: 'https://bppirsahciuxrqzitfxa.supabase.co',
  SUPABASE_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJwcGlyc2FoY2l1eHJxeml0ZnhhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODA0MTExMjcsImV4cCI6MjA5NTk4NzEyN30.Yy3en8gNoTPSVkztlGr6XbUq6ZU3-NHJ4TUIVnZQ4eE',

  /* Interim shared password. Replaced by real login (Supabase Auth) on the roadmap. */
  PASSWORD: 'VBHomes2026!',
  AUTH_TTL_HOURS: 12,

  COMPANY: {
    name: 'Van Buskirk Homes',
    short: 'VBH',
    address: '2571 S Westlake Dr, Sioux Falls, SD 57106',
    phone: '(605) 951-5220',
    values: ['Integrity', 'Teamwork', 'Innovation', 'Excellence', 'Community'],
    serviceRequestUrl: 'https://vanbuskirkco.com/SERVICE-WORK-REQUEST'
  },

  /* ── 2 · PAGES registry ─────────────────────────────────────────────────
     id        matches <body data-vbh-page="…">
     path      extensionless (Netlify pretty URLs); local tools/serve.ps1 mirrors it
     nav       label in the site nav · omit to keep the page out of the nav
     group     nav grouping, left to right: ops → field → reference
     title/sub what the shared page header shows (pages may override)
     tile      shown on the hub landing page (icon + blurb) · omit to hide
     protected true = gate required (shared password today, roles later)
     ─────────────────────────────────────────────────────────────────────── */
  PAGES: [
    { id:'hub',          path:'/hub',          nav:'Hub',          group:'ops',   protected:true,
      title:'Operations Hub', sub:'Van Buskirk Homes · Sioux Falls, SD' },

    { id:'meeting',      path:'/meeting',      nav:'Meeting',      group:'ops',   protected:true,
      title:'Production Meeting', sub:'Tuesdays · 9:00–10:00 AM',
      tile:{ icon:'📋', accent:'steel', blurb:'Timed agenda for the Tuesday production meeting — active jobs, starts, action items, warranty. Buildertrend activity feeds the job cards.' } },

    { id:'digest',       path:'/digest',       nav:'Digest',       group:'ops',   protected:true,
      title:'Buildertrend Digest', sub:'What the PMs reported · by job',
      tile:{ icon:'⟲', accent:'gold', blurb:'Every Buildertrend notification since last meeting, grouped by job: client updates, change orders with dollars, comments, and who has gone quiet. Copy or email it to the team.' } },

    { id:'projects',     path:'/projects',     nav:'Projects',     group:'ops',   protected:true,
      title:'Projects Tracker', sub:'Live pipeline · Solds · Escrow · Models · Maintenance',
      tile:{ icon:'🏠', accent:'gold', blurb:'Every active build with phase, % complete, schedule variance, and the latest note. The tracker the meeting and the exec update read from.' } },

    { id:'gantt',        path:'/gantt',        nav:'Timeline',     group:'ops',   protected:true,
      title:'Build Timeline', sub:'New starts on one Gantt · Solds · Models · Prospects',
      tile:{ icon:'📅', accent:'blue', blurb:'Running Gantt of new starts — Solds, Models, and prospective builds on one timeline. Spot the gaps in the schedule.' } },

    { id:'leads',        path:'/leads',        nav:'Leads',        group:'ops',   protected:true,
      title:'Leads Tracker', sub:'Pipeline · Probability · Follow-ups',
      tile:{ icon:'📊', accent:'blue', blurb:'Pipeline overview, lead cards, contact history, follow-ups, and sales data for prospective buyers.' } },

    { id:'weeklyupdate', path:'/weeklyupdate', nav:'Exec Update',  group:'ops',   protected:true,
      title:'Weekly Executive Update', sub:'Ownership briefing · Wednesdays 4:30 PM',
      tile:{ icon:'📈', accent:'navy-gold', blurb:'Ownership briefing — active builds, closings, and top prospects on one page. Live from the tracker, one-click PDF to send.' } },

    { id:'dashboard',    path:'/dashboard',    nav:'Work Orders',  group:'field', protected:true,
      title:'Work Order Dashboard', sub:'Van Buskirk Homes · Maintenance Operations',
      tile:{ icon:'🔧', accent:'green', blurb:'Approve, dispatch, and track development-maintenance work orders. Crew view for field assignments.' } },

    { id:'equipment',    path:'/equipment',    nav:'Assets',       group:'field', protected:true,
      title:'Asset Tracker', sub:'Signage · Cameras · Equipment',
      tile:{ icon:'📷', accent:'amber', blurb:'Signage, cameras, and equipment — location, check-in/out, who\'s holding it, and service status across every job site.' } },

    { id:'standards',    path:'/standards',    nav:'Standards',    group:'ref',   protected:true,
      title:'Accountability & Communication Standards', sub:'Bid procurement · Field reporting · Client communication · Warranty',
      tile:{ icon:'📐', accent:'purple', blurb:'Field reporting, bid procurement, client communication, and service & warranty response — what\'s expected, who owns it, when it\'s due.' } },

    { id:'raci',         path:'/raci',         nav:'RACI',         group:'ref',   protected:true,
      title:'Responsibility Assignment Matrix', sub:'Project lifecycle · Financials · Administration · Meetings',
      tile:{ icon:'🗂️', accent:'navy', blurb:'Role-based responsibility matrix across the full project lifecycle, financials, admin, and standing meetings.' } },

    /* Public forms — no nav entry, no gate. Linked from the hub footer. */
    { id:'workorder',    path:'/',             protected:false, title:'Work Order Request', sub:'Development Maintenance', footer:'Work Order Request Form' },
    { id:'intake',       path:'/intake',       protected:false, title:'Client Intake',      sub:'New lead → Leads Tracker', footer:'Client Intake Form' }
  ],

  /* ── 3 · option lists ─────────────────────────────────────────────────── */
  NEIGHBORHOODS: [
    'The Bluffs of Brandon',
    'Canterbury Heights',
    'Hazeltine',
    'Heritage Pond',
    'Hitchcock Place — Mitchell',
    'Mapleton Highlands',
    'Mydland Estates',
    'River Park',
    'The Legends at Mapleton',
    'Vistas at Stone Ridge',
    'Westwater at Cherry Lake',
    'Willow Ridge',
    'Other / Out of VBC Development'
  ],
  STATUSES: ['New Inquiry','Active Lead','Proposal Sent','Contract Signed','Build Started','Closed - Won','Closed - Lost','On Hold'],
  LEAD_SOURCES: ['Website','Referral','Parade of Homes','Repeat Customer','Internal','Brandt','Social Media','Sign','Other'],
  SALES_REPS: ['Brandt Williams','Jordan Hefner','Justin Vostad','Outside Realtor','Quentin Robertson','Sydney Van Well'],
  FINANCING: ['VB Homes Financed','Client Financed Build','Cash Build'],
  PROJECT_TYPES: ['Custom Home','Spec Home','Townhome','Addition/Remodel'],
  TEMPS: ['🔥 Hot','☀️ Warm','❄️ Cold'],
  GRADES: ['A','B','C','D'],
  URGENCY: ['Immediate (0-3 mo)','Near-term (3-6 mo)','Mid-range (6-12 mo)','Long-range (12+ mo)','Unknown'],
  COMM_PREFS: ['Phone','Email','Text','Any'],
  CONTRACT_STATUSES: ['Not Started','Sent','Signed'],
  DEPOSIT_STATUSES: ['Not Received','Partial','Received'],

  /* ── 4 · roles & rosters ──────────────────────────────────────────────── */
  WORK_ORDERS: {
    /* Role: who approves and dispatches work orders, is cc'd on completions,
       and signs the notification emails. */
    approverName:  VBH_ROLES.opsDirector.name,
    approverTitle: VBH_ROLES.opsDirector.title,
    approverEmail: VBH_ROLES.opsDirector.email,
    /* People who may submit a request (dropdown on the public form). */
    requestors: [
      { name:'Brandt', email:'Brandt.williams@vanbuskirkco.com' },
      { name:'Logan',  email:'Logan.Callahan@vanbuskirkco.com' },
      { name:'Gabbie', email:'Gabbie.hibbert@vanbuskirkco.com' },
      { name:'Clay',   email:'Clay.nelson@vanbuskirkco.com' },
      { name:'Steve',  email:'Steve@vbclink.com' },
      { name:'Jordan', email:'Jordan.hefner@vanbuskirkco.com' },
      { name:'Kelly',  email:'Kelly.boyd@vanbuskirkco.com' }
    ],
    /* Crew a work order can be assigned to (dashboard approval dropdown). */
    crew: [
      { name:'Dallas Westover',         email:'Dallas.westover@vanbuskirkco.com' },
      { name:'Quentin Robertson',       email:'Quentin.robertson@vanbuskirkco.com' },
      { name:'Jordan Hefner - Sub W/O', email:'Jordan.hefner@vanbuskirkco.com' },
      { name:'Josh Isaacson',           email:'Josh.Isaacson@vanbuskirkco.com' },
      { name:'Jackson Breuer',          email:'Jackson.Breuer@vanbuskirkco.com' },
      { name:'Bill Hoffman',            email:'Bill.hoffman@vanbuskirkco.com' },
      { name:'Jacob Bender',            email:'Jacob.bender@vanbuskirkco.com' }
    ]
  },

  /* Who sits in the Tuesday production meeting (meeting.html).
     name     shows on the agenda and as the Send-panel heading
     email    used for the mailto: draft. Blank = Copy button only.
     aliases  what `@name` typing and legacy owner text resolve to (case-insensitive)
     wins     true = gets a row in the Section 1 round-robin */
  MEETING: {
    time: '9:00 – 10:00 AM',
    weekday: 2,   /* 0 = Sunday … 2 = Tuesday */
    team: [
      { name:'Dallas',  email:'Dallas.westover@vanbuskirkco.com',   aliases:['dallas', 'westover', 'dw', 'dallas westover', 'dallas.westover'], wins:true  },
      { name:'Jordan',  email:'Jordan.hefner@vanbuskirkco.com',     aliases:['jordan', 'hefner', 'jh', 'jordan hefner', 'jordan.hefner'], wins:true  },
      { name:'Justin',  email:'Justin.vostad@vanbuskirkco.com',     aliases:['justin', 'vostad', 'jv', 'justin vostad', 'justin.vostad'], wins:true  },
      { name:'Kara',    email:'Kara.lilly@vanbuskirkco.com',        aliases:['kara', 'lilly', 'kl', 'kara lilly', 'kara.lilly'], wins:true  },
      { name:'Quentin', email:'Quentin.robertson@vanbuskirkco.com', aliases:['quentin', 'robertson', 'qr', 'quentin robertson', 'quentin.robertson'], wins:true  },
      { name:'Sydney',  email:'Sydney.vanwell@vanbuskirkco.com',    aliases:['sydney', 'vanwell', 'sv', 'sydney vanwell', 'sydney.vanwell', 'van well', 'sydney van well'], wins:true  },
      { name:'Josh',    email:'Josh.Isaacson@vanbuskirkco.com',     aliases:['josh', 'isaacson', 'ji', 'josh isaacson', 'josh.isaacson'], wins:false },
      { name:'Bill',    email:'Bill.hoffman@vanbuskirkco.com',      aliases:['bill', 'hoffman', 'bh', 'bill hoffman', 'bill.hoffman'], wins:false }
    ]
  }
};

/* Look up a requestor's email by the name stored on a work order. */
function requestorEmail(name) {
  if (!name) return '';
  var r = VBH.WORK_ORDERS.requestors.find(function (x) { return x.name === name; });
  return r ? r.email : '';
}

/* ── 5 · meeting.html reads window.VBH_CONFIG ─────────────────────────── */
window.VBH_CONFIG = {
  password:     VBH.PASSWORD,
  supabaseUrl:  VBH.SUPABASE_URL,
  supabaseAnon: VBH.SUPABASE_KEY,
  meetingTime:  VBH.MEETING.time,
  meetingWeekday: VBH.MEETING.weekday,
  team:         VBH.MEETING.team
};

/* Legacy globals for pages written against the old config.js. Assigned as
   window properties (not const) so a page that declares its own const of the
   same name still parses. New code should read VBH.* directly. */
window.SUPABASE_URL      = VBH.SUPABASE_URL;
window.SUPABASE_ANON_KEY = VBH.SUPABASE_KEY;
window.JORDAN_EMAIL      = VBH.WORK_ORDERS.approverEmail;
window.REQUESTORS        = VBH.WORK_ORDERS.requestors;
window.CREW              = VBH.WORK_ORDERS.crew;
