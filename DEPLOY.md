# VBH Work Order System - Deployment Guide

## What's in this package

Inside the `public/` folder:
- **index.html** - The work order REQUEST form (this is what you'll email out)
- **dashboard.html** - The work order DASHBOARD (this is what you watch on your office screen)
- **config.js** - Configuration with your Supabase credentials
- **db.js** - Database connection helper

## Deploy to Netlify (5 minutes)

### Step 1: Go to Netlify Drop

Open this in your browser: **https://app.netlify.com/drop**

You should be already signed in. If not, sign in first.

### Step 2: Drag and drop

1. Find the `public` folder from this download
2. Drag the entire `public` folder onto the Netlify Drop page
3. Wait about 10-15 seconds while it uploads

### Step 3: Get your URLs

Netlify will generate a random URL like `vibrant-cake-12345.netlify.app`

Your two important URLs:
- **REQUEST FORM (email this out):** `https://your-name.netlify.app/`
- **DASHBOARD (your office screen):** `https://your-name.netlify.app/dashboard.html`

### Step 4 (optional but recommended): Custom name

1. In Netlify, click "Site settings" or "Domain settings"
2. Change site name to something like `vbh-workorders`
3. Now your URLs become:
   - https://vbh-workorders.netlify.app
   - https://vbh-workorders.netlify.app/dashboard.html

## Test it

1. Open the dashboard URL in one browser tab on your office computer
2. Open the request URL in your phone's browser
3. Submit a test work order from your phone
4. Within 1-2 seconds, it should appear on your dashboard - automatically

## Email the link to your team

Send Brandt, Logan, Clay, and Gabby just the REQUEST URL (NOT the dashboard URL). Subject line:

> VBH Work Order Request Form - Save this link for submitting work orders

> Team, use this link any time you need to request maintenance work from the crew: [your-request-url-here]
> 
> Save it as a bookmark on your phone for easy access. It works from anywhere - the office, the field, your truck. Your request will come straight to me for approval and dispatch.

## How it stays in sync

Everything goes through Supabase (your database):
- Crew submits via the request form -> writes to Supabase
- Dashboard receives realtime update -> shows new order immediately
- You approve from dashboard -> writes back to Supabase
- Crew opens dashboard, sees their approved order -> marks Complete
- You see the completion notification in realtime

No more "did it sync?" - everything goes through one shared database in the cloud.

## Updates and maintenance

If you ever need to modify the forms, just edit the HTML files and re-deploy the folder to Netlify (same drag-and-drop). Or come back to me and I can do the changes.

## Future phases

Phase 2 will add:
- Leads Tracker (with Supabase backing)
- Client Intake form
- All four pages unified under one Netlify site with navigation

We'll tackle that once Phase 1 is running smoothly.
