/**
 * @description Constants for the Flash-Flood Early-Warning PoC (Hazard ingest + ML alerting).
 */
public with sharing class CRDisasterConstants {
    public static final String SOURCE_USGS = 'USGS';
    public static final String SOURCE_GDACS = 'GDACS';
    public static final String SOURCE_ML = 'ML_PRECURSOR';

    public static final String RISK_CRITICAL = 'Critical';
    public static final String RISK_HIGH = 'High';
    public static final String RISK_MEDIUM = 'Medium';
    public static final String RISK_LOW = 'Low';

    public static final String PHASE_PRECURSOR = 'Precursor';
    public static final String PHASE_IMMINENT = 'Imminent';
    public static final String PHASE_IMPACT = 'Impact';

    public static final String EVENT_EARTHQUAKE = 'Earthquake';
    public static final String EVENT_LANDSLIDE = 'Landslide';
    public static final String EVENT_FLOOD = 'Flood';
    public static final String EVENT_GLACIAL_LAKE = 'Glacial_Lake_Change';

    public static final String NOTIFICATION_TYPE = 'Hazard_Alert';
    public static final String RESPONSE_GROUP = 'Disaster_Response_Team';

    public static final Double MEDIUM_THRESHOLD = 30.0;
}