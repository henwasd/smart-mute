// Helper to get domain from URL
function getDomain(url) {
  try {
    return new URL(url).hostname;
  } catch (e) {
    return null;
  }
}

// Check if a URL matches any pattern in the whitelist
function matchesWhitelist(url, whitelist) {
  if (!url || !Array.isArray(whitelist)) return false;
  const lowerUrl = url.toLowerCase();
  return whitelist.some(pattern => pattern && lowerUrl.includes(pattern.toLowerCase()));
}

async function isWhitelisted(url) {
  const data = await chrome.storage.local.get({ whitelist: [] });
  return matchesWhitelist(url, data.whitelist);
}

// Main logic to mute other tabs of the same domain
async function handleAudioTabChange(targetTab) {
  const data = await chrome.storage.local.get({
    extensionEnabled: true,
    allowDifferentSites: true,
    whitelist: []
  });
  if (!data.extensionEnabled) return;

  if (!targetTab.url) return;

  // Sites in the exceptions list do not participate in the extension:
  // they never mute other tabs when playing audio and are never muted.
  if (matchesWhitelist(targetTab.url, data.whitelist)) return;

  const targetDomain = getDomain(targetTab.url);
  if (!targetDomain && data.allowDifferentSites) return;

  const allTabs = await chrome.tabs.query({});
  
  // 1. Check if there's an active audible tab that should take precedence
  if (!targetTab.active) {
    const conflictingActiveTab = allTabs.find(t => 
      t.id !== targetTab.id && 
      t.active && 
      t.audible && 
      !matchesWhitelist(t.url, data.whitelist) &&
      (!data.allowDifferentSites || getDomain(t.url) === targetDomain)
    );
    
    if (conflictingActiveTab) {
      // If a background tab becomes audible but there's an active audible tab, mute the background one
      if (!targetTab.mutedInfo || !targetTab.mutedInfo.muted) {
        chrome.tabs.update(targetTab.id, { muted: true });
      }
      return;
    }
  }

  // 2. If we reach here, targetTab is allowed to play. Unmute it.
  if (targetTab.audible && targetTab.mutedInfo && targetTab.mutedInfo.muted) {
    await chrome.tabs.update(targetTab.id, { muted: false });
  }

  // 3. Mute all other conflicting tabs
  for (const t of allTabs) {
    if (t.id === targetTab.id) continue;
    if (matchesWhitelist(t.url, data.whitelist)) continue;
    
    const tDomain = getDomain(t.url);
    let shouldMute = false;
    
    if (!data.allowDifferentSites) {
      shouldMute = true;
    } else if (tDomain === targetDomain) {
      shouldMute = true;
    }

    if (shouldMute) {
      if (!t.mutedInfo || !t.mutedInfo.muted) {
        chrome.tabs.update(t.id, { muted: true });
      }
    }
  }
}

// Listen for tab updates (e.g., when a tab starts playing audio)
chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.audible === true) {
    await handleAudioTabChange(tab);
  }
});

// Listen for tab activation (when user switches to a different tab)
chrome.tabs.onActivated.addListener(async (activeInfo) => {
  try {
    const tab = await chrome.tabs.get(activeInfo.tabId);
    if (tab.audible) {
      await handleAudioTabChange(tab);
    }
  } catch (e) {
    console.error("Error handling tab activation:", e);
  }
});
