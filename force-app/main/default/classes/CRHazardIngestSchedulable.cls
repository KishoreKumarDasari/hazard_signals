/**
 * @description Schedulable entry point for the flash-flood hazard ingest. Enqueues the callout
 *              queueable. Schedule several staggered instances (e.g. every 15 min) for sub-hourly
 *              polling, since Apex scheduling granularity is one hour per job.
 *
 *              Example (Anonymous Apex):
 *              System.schedule('Hazard Ingest 00', '0 0 * * * ?', new CRHazardIngestSchedulable());
 */
global without sharing class CRHazardIngestSchedulable implements Schedulable { //NOPMD - Schedulable classes must be global

    global void execute(SchedulableContext ctx) {
        System.enqueueJob(new CRHazardIngestQueueable());
    }
}