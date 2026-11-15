# Henge fork scan, step 1: list every fork, compare each recently pushed branch with upstream main,
# and write forks.json, pr_heads.json, compare-results.json, candidates.json, errors.json and one
# patch bundle per candidate branch under diffs/. Needs an authenticated `gh`. Run it in an empty directory.
# Edit CUT (and BR_CUT) to the time of the previous scan; set the EXCLUDE environment variable to your own fork (lowercase owner/repo).
import json, subprocess, time, sys, os
EXCLUDE=os.environ.get("EXCLUDE","").lower()
os.makedirs("diffs",exist_ok=True)
CUT="2026-11-12T12:00:00Z"; BR_CUT="2026-11-01T00:00:00Z"
errors=[]
def gh(args, accept=None, paginate=False):
    cmd=["gh","api"]+(["--paginate","--slurp"] if paginate else [])+(["-H",f"Accept: {accept}"] if accept else [])+args
    for attempt in range(4):
        r=subprocess.run(cmd,capture_output=True,text=True)
        if r.returncode==0: return r.stdout
        e=r.stderr
        if "rate limit" in e.lower() or "403" in e or "429" in e:
            time.sleep(60*(attempt+1)); continue
        errors.append({"cmd":" ".join(args),"err":e.strip()[:300]}); return None
    errors.append({"cmd":" ".join(args),"err":"rate-limited"}); return None
def pj(s):
    if s is None: return None
    # paginate concatenates arrays
    v=json.loads(s)
    if isinstance(v,list) and v and isinstance(v[0],list): v=[x for page in v for x in page]
    return v
up=pj(gh(["repos/Leviidev/Henge/branches/main"]))["commit"]["sha"]
forks=pj(gh(["repos/Leviidev/Henge/forks?per_page=100"],paginate=True))
allf=[]
for f in forks:
    allf.append(f)
    if f.get("forks_count",0)>0:
        sub=pj(gh([f"repos/{f['full_name']}/forks?per_page=100"],paginate=True)) or []
        for s in sub: s["_parent"]=f["full_name"]; allf.append(s)
out=[{"full_name":f["full_name"],"default_branch":f["default_branch"],"pushed_at":f["pushed_at"],"created_at":f["created_at"],
      "license":(f.get("license") or {}).get("spdx_id"),"parent":f.get("_parent","Leviidev/Henge")} for f in allf]
json.dump({"upstream_main":up,"forks":out},open("forks.json","w"),indent=1)
prs=pj(gh(["repos/Leviidev/Henge/pulls?state=all&per_page=100"],paginate=True)) or []
pr_heads={}
for p in prs:
    h=p.get("head") or {}
    if h.get("sha"): pr_heads[h["sha"]]=p["number"]
    if h.get("repo"): pr_heads[(h["repo"]["full_name"],h["ref"])]=p["number"]
json.dump({str(k):v for k,v in pr_heads.items()},open("pr_heads.json","w"))
results=[]; cands=[]
for f in out:
    fn=f["full_name"]; o=fn.split("/")[0]; repo=fn.split("/")[1]
    if fn.lower()==EXCLUDE: continue
    if f["pushed_at"]<CUT and f["created_at"]<CUT:
        results.append({"fork":fn,"status":"skip-not-pushed-since-cut"}); continue
    branches=[(f["default_branch"],True)]
    bl=pj(gh([f"repos/{fn}/branches?per_page=100"],paginate=True)) or []
    for b in bl:
        if b["name"]==f["default_branch"]: continue
        c=pj(gh([f"repos/{fn}/commits/{b['commit']['sha']}"]))
        d=c and c["commit"]["committer"]["date"]
        if d and d>=BR_CUT: branches.append((b["name"],False))
    for br,isdef in branches:
        cmp=pj(gh([f"repos/Leviidev/Henge/compare/main...{o}:{repo}:{br}"]))
        if not cmp: results.append({"fork":fn,"branch":br,"status":"compare-error"}); continue
        commits=[{"sha":c["sha"],"author":(c["commit"]["author"] or {}).get("name"),"date":c["commit"]["committer"]["date"],"message":c["commit"]["message"].split("\n")[0]} for c in cmp["commits"]]
        newc=[c for c in commits if c["date"]>=CUT and c["sha"] not in pr_heads]
        inpr=pr_heads.get((fn,br))
        rec={"fork":fn,"branch":br,"default":isdef,"ahead_by":cmp["ahead_by"],"behind_by":cmp["behind_by"],"head":cmp["commits"][-1]["sha"] if commits else None,
             "commits":commits,"new_commits":newc,"pr":inpr,"license":f["license"],"new_fork":f["created_at"]>=CUT}
        if cmp["ahead_by"]==0: rec["status"]="not-ahead"
        elif inpr: rec["status"]="in-upstream-pr"
        elif not newc: rec["status"]="skip-covered"
        else:
            rec["status"]="candidate"
            files=cmp.get("files",[])
            parts=[]
            for fl in files:
                p=fl.get("patch")
                if p is None: parts.append(f"### {fl['filename']} ({fl['status']}, +{fl['additions']}/-{fl['deletions']}) [no patch: binary or too large]\n"); continue
                L=p.split("\n"); tr=len(L)>1500
                parts.append(f"### {fl['filename']} ({fl['status']}, +{fl['additions']}/-{fl['deletions']})"+(" [TRUNCATED to 1500 lines]" if tr else "")+"\n"+"\n".join(L[:1500])+"\n")
            hdr=f"# {fn} {br} ahead {cmp['ahead_by']} behind {cmp['behind_by']} license {f['license']}\n# files in compare: {len(files)}"+(" (API caps at 300)" if len(files)>=300 else "")+"\n"+"\n".join(f"# {c['sha'][:10]} {c['date']} {c['author']}: {c['message']}" for c in commits)+"\n\n"
            pf=f"diffs/{o}__{repo}__{br.replace('/','_')}.patch"; open(pf,"w").write(hdr+"\n".join(parts)); rec["patch"]=pf
            cands.append(rec)
        results.append(rec)
json.dump(results,open("compare-results.json","w"),indent=1)
json.dump(cands,open("candidates.json","w"),indent=1)
json.dump(errors,open("errors.json","w"),indent=1)
print(up,len(out),len(results),len(cands),len(errors))
