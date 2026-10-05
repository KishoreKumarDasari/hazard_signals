/**
 * @description Queueable that performs the outbound callouts to public hazard data sources
 *              (USGS, GDACS) and the external ML precursor model, parses the responses into
 *              scored ParsedHazard records, then hands them to CRHazardRiskService for DML.
 *              Callouts are done first, DML afterwards (Salesforce forbids callout-after-DML).
 */
public without sharing class CRHazardIngestQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final Integer CALLOUT_TIMEOUT = 120000;

    public void execute(QueueableContext context) {
        List<Hazard_Source__mdt> sources = getActiveSources();
        List<Hazard_Region__mdt> regions = getActiveRegions();

        Map<String, Decimal> criticalBySource = new Map<String, Decimal>();
        Map<String, Decimal> highBySource = new Map<String, Decimal>();
        for (Hazard_Source__mdt src : sources) {
            criticalBySource.put(src.Source_Key__c, src.Critical_Threshold__c);
            highBySource.put(src.Source_Key__c, src.High_Threshold__c);
        }

        List<CRHazardRiskService.ParsedHazard> collected = new List<CRHazardRiskService.ParsedHazard>();

        // Phase 1 — all callouts (no DML yet).
        for (Hazard_Source__mdt src : sources) {
            try {
                if (CRDisasterConstants.SOURCE_USGS.equals(src.Source_Key__c)) {
                    collected.addAll(ingestUsgs(src, regions));
                } else if (CRDisasterConstants.SOURCE_GDACS.equals(src.Source_Key__c)) {
                    collected.addAll(ingestGdacs(src, regions));
                } else if (CRDisasterConstants.SOURCE_ML.equals(src.Source_Key__c)) {
                    collected.addAll(ingestMl(src));
                }
            } catch (Exception ex) {
                System.debug(LoggingLevel.ERROR, 'Ingest failed for ' + src.Source_Key__c + ': ' + ex.getMessage());
            }
        }

        // Phase 2 — DML + notifications.
        CRHazardRiskService.process(collected, criticalBySource, highBySource);
    }

    private List<Hazard_Source__mdt> getActiveSources() {
        return [
            SELECT Source_Key__c, Named_Credential__c, Base_Path__c, Critical_Threshold__c, High_Threshold__c
            FROM Hazard_Source__mdt
            WHERE Active__c = true
        ];
    }

    private List<Hazard_Region__mdt> getActiveRegions() {
        return [
            SELECT Region_Name__c, Continent__c, Country__c, Min_Latitude__c, Max_Latitude__c,
                   Min_Longitude__c, Max_Longitude__c, Min_Magnitude__c
            FROM Hazard_Region__mdt
            WHERE Active__c = true
        ];
    }

    // ---------------------------------------------------------------------
    // USGS — one callout per region bounding box (GeoJSON).
    // ---------------------------------------------------------------------
    private List<CRHazardRiskService.ParsedHazard> ingestUsgs(Hazard_Source__mdt src, List<Hazard_Region__mdt> regions) {
        List<CRHazardRiskService.ParsedHazard> result = new List<CRHazardRiskService.ParsedHazard>();
        String start = Datetime.now().addDays(-1).format('yyyy-MM-dd', 'GMT');

        for (Hazard_Region__mdt region : regions) {
            Decimal minMag = region.Min_Magnitude__c == null ? 4.5 : region.Min_Magnitude__c;
            String path = src.Base_Path__c
                .replace('{minmag}', String.valueOf(minMag))
                .replace('{minlat}', String.valueOf(region.Min_Latitude__c))
                .replace('{maxlat}', String.valueOf(region.Max_Latitude__c))
                .replace('{minlon}', String.valueOf(region.Min_Longitude__c))
                .replace('{maxlon}', String.valueOf(region.Max_Longitude__c))
                .replace('{start}', start);

            String body = doGet(src.Named_Credential__c, path);
            if (String.isBlank(body)) {
                continue;
            }
            result.addAll(parseUsgs(body, region));
        }
        return result;
    }

    @TestVisible
    private List<CRHazardRiskService.ParsedHazard> parseUsgs(String body, Hazard_Region__mdt region) {
        List<CRHazardRiskService.ParsedHazard> result = new List<CRHazardRiskService.ParsedHazard>();
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        List<Object> features = (List<Object>) root.get('features');
        if (features == null) {
            return result;
        }

        for (Object fObj : features) {
            Map<String, Object> feature = (Map<String, Object>) fObj;
            Map<String, Object> props = (Map<String, Object>) feature.get('properties');
            Map<String, Object> geom = (Map<String, Object>) feature.get('geometry');
            if (props == null) {
                continue;
            }

            Decimal mag = toDecimal(props.get('mag'));
            String alert = (String) props.get('alert');
            CRHazardRiskService.ParsedHazard ph = new CRHazardRiskService.ParsedHazard();
            Hazard_Signal__c s = ph.signal;
            s.Source_System__c = CRDisasterConstants.SOURCE_USGS;
            s.Event_Type__c = CRDisasterConstants.EVENT_EARTHQUAKE;
            s.Source_Record_Id__c = 'USGS-' + String.valueOf(feature.get('id'));
            s.Location_Name__c = (String) props.get('place');
            s.Observed_Value__c = mag;
            s.Observation_Time__c = toDatetime(props.get('time'));
            s.Primary_Source_URL__c = (String) props.get('url');
            s.Alert_Phase__c = CRDisasterConstants.PHASE_IMPACT;
            s.Lead_Time_Hours__c = 0;
            s.Risk_Score__c = scoreUsgs(mag, alert);
            applyRegion(s, region);
            setCoordinates(s, geom);
            result.add(ph);
        }
        return result;
    }

    @TestVisible
    private static Decimal scoreUsgs(Decimal mag, String pagerAlert) {
        Decimal base;
        if (mag == null) {
            base = 30;
        } else if (mag >= 7) {
            base = 92;
        } else if (mag >= 6) {
            base = 78;
        } else if (mag >= 5) {
            base = 58;
        } else if (mag >= 4.5) {
            base = 44;
        } else {
            base = 30;
        }
        if ('red'.equalsIgnoreCase(pagerAlert)) {
            base += 15;
        } else if ('orange'.equalsIgnoreCase(pagerAlert)) {
            base += 8;
        } else if ('yellow'.equalsIgnoreCase(pagerAlert)) {
            base += 3;
        }
        return Math.min(base, 100);
    }

    // ---------------------------------------------------------------------
    // GDACS — single global callout, filtered to active region boxes.
    // ---------------------------------------------------------------------
    private List<CRHazardRiskService.ParsedHazard> ingestGdacs(Hazard_Source__mdt src, List<Hazard_Region__mdt> regions) {
        String body = doGet(src.Named_Credential__c, src.Base_Path__c);
        if (String.isBlank(body)) {
            return new List<CRHazardRiskService.ParsedHazard>();
        }
        return parseGdacs(body, regions);
    }

    @TestVisible
    private List<CRHazardRiskService.ParsedHazard> parseGdacs(String body, List<Hazard_Region__mdt> regions) {
        List<CRHazardRiskService.ParsedHazard> result = new List<CRHazardRiskService.ParsedHazard>();
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        List<Object> features = (List<Object>) root.get('features');
        if (features == null) {
            return result;
        }

        for (Object fObj : features) {
            Map<String, Object> feature = (Map<String, Object>) fObj;
            Map<String, Object> props = (Map<String, Object>) feature.get('properties');
            Map<String, Object> geom = (Map<String, Object>) feature.get('geometry');
            if (props == null || geom == null) {
                continue;
            }

            List<Object> coords = (List<Object>) geom.get('coordinates');
            if (coords == null || coords.size() < 2) {
                continue;
            }
            Decimal lon = toDecimal(coords[0]);
            Decimal lat = toDecimal(coords[1]);
            Hazard_Region__mdt region = matchRegion(lat, lon, regions);
            if (region == null) {
                continue;
            }

            String eventType = (String) props.get('eventtype');
            String alertLevel = (String) props.get('alertlevel');
            CRHazardRiskService.ParsedHazard ph = new CRHazardRiskService.ParsedHazard();
            Hazard_Signal__c s = ph.signal;
            s.Source_System__c = CRDisasterConstants.SOURCE_GDACS;
            s.Event_Type__c = mapGdacsEventType(eventType);
            s.Source_Record_Id__c = 'GDACS-' + String.valueOf(props.get('eventid')) + '-' + String.valueOf(props.get('episodeid'));
            s.Location_Name__c = (String) props.get('name');
            s.Country__c = (String) props.get('country');
            s.Latitude__c = lat;
            s.Longitude__c = lon;
            s.Observation_Time__c = toDatetime(props.get('fromdate'));
            s.Alert_Phase__c = CRDisasterConstants.PHASE_IMPACT;
            s.Lead_Time_Hours__c = 0;
            s.Risk_Score__c = scoreGdacs(alertLevel);
            s.Region__c = region.Region_Name__c;
            s.Continent__c = region.Continent__c;
            if (String.isBlank(s.Country__c)) {
                s.Country__c = region.Country__c;
            }
            addGdacsMedia(ph, props);
            result.add(ph);
        }
        return result;
    }

    private void addGdacsMedia(CRHazardRiskService.ParsedHazard ph, Map<String, Object> props) {
        String icon = (String) props.get('icon');
        if (String.isNotBlank(icon)) {
            ph.media.add(buildMedia(ph.signal.Source_Record_Id__c + '-icon', icon, 'Map', 'GDACS event map'));
        }
        Object urlObj = props.get('url');
        if (urlObj instanceof Map<String, Object>) {
            String report = (String) ((Map<String, Object>) urlObj).get('report');
            if (String.isNotBlank(report)) {
                ph.media.add(buildMedia(ph.signal.Source_Record_Id__c + '-report', report, 'Redirect', 'Open GDACS report'));
            }
        }
    }

    @TestVisible
    private static Decimal scoreGdacs(String alertLevel) {
        if ('Red'.equalsIgnoreCase(alertLevel)) {
            return 85;
        } else if ('Orange'.equalsIgnoreCase(alertLevel)) {
            return 60;
        } else if ('Green'.equalsIgnoreCase(alertLevel)) {
            return 30;
        }
        return 20;
    }

    private static String mapGdacsEventType(String eventType) {
        if ('FL'.equalsIgnoreCase(eventType)) {
            return CRDisasterConstants.EVENT_FLOOD;
        } else if ('EQ'.equalsIgnoreCase(eventType)) {
            return CRDisasterConstants.EVENT_EARTHQUAKE;
        } else if ('LS'.equalsIgnoreCase(eventType)) {
            return CRDisasterConstants.EVENT_LANDSLIDE;
        }
        return CRDisasterConstants.EVENT_FLOOD;
    }

    // ---------------------------------------------------------------------
    // ML precursor — external Gradio model returns forecast signals (days ahead).
    // ---------------------------------------------------------------------
    private List<CRHazardRiskService.ParsedHazard> ingestMl(Hazard_Source__mdt src) {
        String body = doGet(src.Named_Credential__c, src.Base_Path__c);
        if (String.isBlank(body)) {
            return new List<CRHazardRiskService.ParsedHazard>();
        }
        return parseMl(body);
    }

    @TestVisible
    private List<CRHazardRiskService.ParsedHazard> parseMl(String body) {
        List<CRHazardRiskService.ParsedHazard> result = new List<CRHazardRiskService.ParsedHazard>();
        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
        List<Object> signals = (List<Object>) root.get('signals');
        if (signals == null) {
            return result;
        }

        for (Object sObj : signals) {
            Map<String, Object> item = (Map<String, Object>) sObj;
            CRHazardRiskService.ParsedHazard ph = new CRHazardRiskService.ParsedHazard();
            Hazard_Signal__c s = ph.signal;
            s.Source_System__c = 'ML_Model';
            s.Event_Type__c = CRDisasterConstants.EVENT_GLACIAL_LAKE;
            s.Source_Record_Id__c = 'ML-' + String.valueOf(item.get('id'));
            s.Location_Name__c = (String) item.get('lake');
            s.Region__c = (String) item.get('region');
            s.Continent__c = (String) item.get('continent');
            s.Country__c = (String) item.get('country');
            s.Latitude__c = toDecimal(item.get('lat'));
            s.Longitude__c = toDecimal(item.get('lon'));
            s.Observed_Value__c = toDecimal(item.get('observed_area_km2'));
            s.Baseline_Value__c = toDecimal(item.get('baseline_area_km2'));
            s.Risk_Score__c = toDecimal(item.get('risk_score'));
            s.Lead_Time_Hours__c = toDecimal(item.get('lead_time_hours'));
            s.Alert_Phase__c = CRDisasterConstants.PHASE_PRECURSOR;
            s.Primary_Source_URL__c = (String) item.get('source_url');
            if (s.Observed_Value__c != null && s.Baseline_Value__c != null && s.Baseline_Value__c != 0) {
                s.Change_Percent__c = ((s.Observed_Value__c - s.Baseline_Value__c) / s.Baseline_Value__c) * 100;
            }
            if (s.Lead_Time_Hours__c != null) {
                s.Predicted_Impact_Window__c = System.now().addMinutes((Integer) (s.Lead_Time_Hours__c * 60));
            }
            addMlMedia(ph, item);
            result.add(ph);
        }
        return result;
    }

    private void addMlMedia(CRHazardRiskService.ParsedHazard ph, Map<String, Object> item) {
        Object imagesObj = item.get('images');
        if (!(imagesObj instanceof List<Object>)) {
            return;
        }
        Integer idx = 0;
        for (Object imgObj : (List<Object>) imagesObj) {
            Map<String, Object> img = (Map<String, Object>) imgObj;
            String url = (String) img.get('url');
            if (String.isBlank(url)) {
                continue;
            }
            Hazard_Media__c m = buildMedia(
                ph.signal.Source_Record_Id__c + '-img' + idx,
                url,
                (String) img.get('type'),
                (String) img.get('caption')
            );
            m.Sort_Order__c = idx;
            ph.media.add(m);
            idx++;
        }
    }

    // ---------------------------------------------------------------------
    // Shared helpers
    // ---------------------------------------------------------------------
    @TestVisible
    private String doGet(String namedCredential, String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCredential + path);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setHeader('User-Agent', 'Salesforce-FlashFlood-PoC');
        req.setTimeout(CALLOUT_TIMEOUT);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
            return res.getBody();
        }
        System.debug(LoggingLevel.WARN, 'Callout ' + path + ' returned ' + res.getStatusCode());
        return null;
    }

    private static Hazard_Media__c buildMedia(String refId, String url, String type, String caption) {
        return new Hazard_Media__c(
            Source_Ref_Id__c = refId,
            Media_URL__c = url,
            Media_Type__c = String.isBlank(type) ? 'Other' : type,
            Caption__c = caption
        );
    }

    private static void applyRegion(Hazard_Signal__c s, Hazard_Region__mdt region) {
        if (region == null) {
            return;
        }
        s.Region__c = region.Region_Name__c;
        s.Continent__c = region.Continent__c;
        s.Country__c = region.Country__c;
    }

    private static void setCoordinates(Hazard_Signal__c s, Map<String, Object> geom) {
        if (geom == null) {
            return;
        }
        List<Object> coords = (List<Object>) geom.get('coordinates');
        if (coords != null && coords.size() >= 2) {
            s.Longitude__c = toDecimal(coords[0]);
            s.Latitude__c = toDecimal(coords[1]);
        }
    }

    private static Hazard_Region__mdt matchRegion(Decimal lat, Decimal lon, List<Hazard_Region__mdt> regions) {
        if (lat == null || lon == null) {
            return null;
        }
        for (Hazard_Region__mdt r : regions) {
            if (lat >= r.Min_Latitude__c && lat <= r.Max_Latitude__c
                && lon >= r.Min_Longitude__c && lon <= r.Max_Longitude__c) {
                return r;
            }
        }
        return null;
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer || value instanceof Long || value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value));
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception ex) {
            return null;
        }
    }

    private static Datetime toDatetime(Object epochMillis) {
        Decimal ms = toDecimal(epochMillis);
        return ms == null ? null : Datetime.newInstance(ms.longValue());
    }
}