# Plan: Submit netbox.el to MELPA

## Overview

MELPA is a community-maintained package archive for Emacs. To get your package listed there, you submit a "recipe" file via a Pull Request (PR) to the MELPA GitHub repository. A PR is basically a way to propose a change to someone else's repository — GitHub handles the review process from there.

**⚠️ One known issue:** The GitHub repo `sraupach/netbox.el` was created today (2026-05-07). MELPA's checklist asks that a package has been "maintained in a public repository for 1 month or more." You may need to wait, or explain in the PR that the code was developed over a longer period privately. MELPA maintainers evaluate this case-by-case.

---

## Steps

### Step 1 — Push your fixes to GitHub

The package header, license, tests, and `.gitignore` are present. Push the
current `main` branch to GitHub:

```bash
git push origin main
```

Verify at: https://github.com/sraupach/netbox.el

---

### Step 2 — Run quality checks in Emacs

MELPA requires these checks. Do them in Emacs before submitting:

1. **package-lint** — install it: `M-x package-install RET package-lint RET`  
   Then open `netbox.el` and run: `M-x package-lint-current-buffer`  
   Fix any errors it reports.

2. **checkdoc** — with `netbox.el` open: `M-x checkdoc`  
   Fix documentation string warnings.

3. **byte-compile** — `M-x byte-compile-file` on `netbox.el`  
   There must be zero errors and ideally zero warnings.

---

### Step 3 — Fork the MELPA repository

1. Go to: https://github.com/melpa/melpa
2. Click the **Fork** button (top-right)
3. This creates your own copy at: `https://github.com/sraupach/melpa`

---

### Step 4 — Clone your MELPA fork

```bash
git clone https://github.com/sraupach/melpa.git
cd melpa
```

---

### Step 5 — Create the recipe file

Create a file named exactly `netbox` (no extension) inside the `recipes/` directory:

```bash
# Inside the melpa clone:
cat > recipes/netbox << 'EOF'
(netbox
 :fetcher github
 :repo "sraupach/netbox.el"
 :files ("netbox.el"))
EOF
```

The `:files` line excludes the regression test file (`test-netbox.el`) from
the distributed package.

---

### Step 6 — (Optional) Test the recipe locally

If you have GNU make and a standard Emacs available:

```bash
# Inside the melpa clone:
make recipes/netbox
```

This downloads your package and builds it. If it fails, fix the issue before submitting.

---

### Step 7 — Push your recipe and open a Pull Request

```bash
# Inside the melpa clone:
git checkout -b add-netbox-recipe
git add recipes/netbox
git commit -m "Add recipe for netbox"
git push origin add-netbox-recipe
```

Then:
1. Go to: https://github.com/melpa/melpa
2. GitHub will show a yellow banner: "add-netbox-recipe had recent pushes" → click **Compare & pull request**
3. Set the title: **"Add recipe for netbox"**
4. Fill in the PR template:
   - Summary: "Emacs interface for browsing and searching a NetBox instance via its REST API"
   - Link: https://github.com/sraupach/netbox.el
   - Association: "I am the author and maintainer"
   - Communications: "None needed"
   - Check all the checklist boxes (assuming checks pass)
5. Click **Create pull request**

---

### Step 8 — Respond to feedback

MELPA maintainers will review your PR. It can take a few days to a few weeks. They may ask you to:
- Fix code style issues
- Add or fix docstrings
- Adjust the recipe

When they do, make the changes in your `sraupach/netbox.el` repo (and push), or adjust the recipe file in your MELPA fork branch, then mention the fix in a PR comment.

---

## Recipe content (for reference)

```elisp
(netbox
 :fetcher github
 :repo "sraupach/netbox.el"
 :files ("netbox.el"))
```
